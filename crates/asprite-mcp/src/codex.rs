use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, Command},
    sync::{Mutex, broadcast, oneshot},
    time,
};

pub fn find_executable(configured: Option<&Path>) -> Option<PathBuf> {
    if let Some(path) = configured {
        return path
            .is_absolute()
            .then(|| path.to_path_buf())
            .filter(|p| p.is_file());
    }
    let name = if cfg!(windows) { "codex.exe" } else { "codex" };
    let mut candidates = Vec::new();
    if let Some(paths) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&paths).map(|p| p.join(name)));
    }
    if cfg!(windows)
        && let Some(local) = dirs::data_local_dir()
    {
        candidates.push(local.join("Programs/OpenAI/Codex/bin/codex.exe"));
    }
    candidates.into_iter().find(|p| p.is_file())
}

enum Cleanup {
    Turn(String),
    Login,
}

impl Cleanup {
    fn request(&self, result: &Value) -> Option<(&'static str, Value)> {
        match self {
            Self::Turn(thread) => Some((
                "turn/interrupt",
                json!({"threadId":thread, "turnId":result["turn"]["id"].as_str()?}),
            )),
            Self::Login => Some((
                "account/login/cancel",
                json!({"loginId":result["loginId"].as_str()?}),
            )),
        }
    }
}

struct PendingCall {
    sender: oneshot::Sender<std::result::Result<Value, String>>,
    cleanup: Option<Cleanup>,
}

type Pending = HashMap<u64, PendingCall>;

struct Transport {
    input: Mutex<ChildStdin>,
    pending: Mutex<Pending>,
    events: broadcast::Sender<Value>,
    sequence: AtomicU64,
    alive: AtomicBool,
}

pub struct Client {
    transport: Arc<Transport>,
    _child: Child,
}

impl Client {
    pub async fn start(executable: &Path, directory: &Path) -> Result<Arc<Self>> {
        std::fs::create_dir_all(directory)?;
        let mut command = Command::new(executable);
        command.args(["app-server", "--listen", "stdio://"]);
        for setting in [
            "mcp_servers={}",
            "plugins={}",
            "apps._default.enabled=false",
            "features.shell_tool=false",
            "features.unified_exec=false",
            "features.apply_patch_freeform=false",
            "agents.enabled=false",
            "web_search=\"disabled\"",
        ] {
            command.args(["-c", setting]);
        }
        command
            .current_dir(directory)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        #[cfg(windows)]
        command.creation_flags(0x0800_0000);
        let mut child = command
            .spawn()
            .context("Nao foi possivel iniciar o Codex. Confira o executavel nas conexoes.")?;
        let output = child.stdout.take().context("Codex stdout unavailable")?;
        let (events, _) = broadcast::channel(1024);
        let transport = Arc::new(Transport {
            input: Mutex::new(child.stdin.take().context("Codex stdin unavailable")?),
            pending: Mutex::new(HashMap::new()),
            events,
            sequence: AtomicU64::new(1),
            alive: AtomicBool::new(true),
        });
        let reader = transport.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(output).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(message) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if message.get("method").is_some() {
                    if message.get("id").is_some() && message["method"] != "item/tool/call" {
                        let reply = json!({"id":message["id"], "error":{"code":-32601, "message":"This client only executes Rust Pixel drawing tools."}});
                        let _ = send(&reader, &reply).await;
                    } else {
                        let _ = reader.events.send(message);
                    }
                } else if let Some(id) = message["id"].as_u64() {
                    let pending = reader.pending.lock().await.remove(&id);
                    let Some(pending) = pending else { continue };
                    let result = if message.get("error").is_some() {
                        Err(message["error"]["message"]
                            .as_str()
                            .unwrap_or("Codex request failed")
                            .to_owned())
                    } else {
                        Ok(message["result"].clone())
                    };
                    if let Err(Ok(abandoned)) = pending.sender.send(result)
                        && let Some((method, params)) = pending
                            .cleanup
                            .and_then(|cleanup| cleanup.request(&abandoned))
                    {
                        let id = reader.sequence.fetch_add(1, Ordering::Relaxed);
                        let _ = send(&reader, &json!({"id":id, "method":method, "params":params}))
                            .await;
                    }
                }
            }
            reader.alive.store(false, Ordering::Release);
            for (_, pending) in reader.pending.lock().await.drain() {
                let _ = pending
                    .sender
                    .send(Err("O Codex encerrou a conexao. Reabra o painel.".into()));
            }
        });
        let client = Arc::new(Self {
            transport,
            _child: child,
        });
        client.request("initialize", json!({
            "clientInfo":{"name":"rust_pixel", "title":"Rust Pixel", "version":env!("CARGO_PKG_VERSION")},
            "capabilities":{"experimentalApi":true},
        })).await.context("Atualize o Codex CLI para usar a integracao app-server.")?;
        send(&client.transport, &json!({"method":"initialized"})).await?;
        Ok(client)
    }

    pub fn alive(&self) -> bool {
        self.transport.alive.load(Ordering::Acquire)
    }
    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.transport.events.subscribe()
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        ensure!(self.alive(), "O Codex nao esta conectado.");
        let id = self.transport.sequence.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        let cleanup = match method {
            "turn/start" => params["threadId"]
                .as_str()
                .map(|thread| Cleanup::Turn(thread.into())),
            "account/login/start" => Some(Cleanup::Login),
            _ => None,
        };
        self.transport
            .pending
            .lock()
            .await
            .insert(id, PendingCall { sender, cleanup });
        if let Err(error) = send(
            &self.transport,
            &json!({"id":id, "method":method, "params":params}),
        )
        .await
        {
            self.transport.pending.lock().await.remove(&id);
            return Err(error);
        }
        let result = time::timeout(Duration::from_secs(45), receiver).await;
        if result.is_ok() {
            self.transport.pending.lock().await.remove(&id);
        }
        result
            .context("O Codex demorou para responder.")?
            .context("A conexao com o Codex foi interrompida.")?
            .map_err(anyhow::Error::msg)
    }

    pub async fn reply(&self, id: &Value, result: Value) -> Result<()> {
        send(&self.transport, &json!({"id":id, "result":result})).await
    }

    pub async fn account(&self) -> Result<Value> {
        self.request("account/read", json!({"refreshToken":false}))
            .await
    }

    pub async fn models(&self) -> Result<Value> {
        let mut models = Vec::new();
        let mut cursor = Value::Null;
        for _ in 0..10 {
            let page = self
                .request(
                    "model/list",
                    json!({"limit":100, "includeHidden":false, "cursor":cursor}),
                )
                .await?;
            for model in page["data"]
                .as_array()
                .context("O Codex nao retornou o catalogo de modelos.")?
            {
                models.push(json!({"id":model["model"].as_str().or(model["id"].as_str()),
                    "name":model["displayName"], "default":model["isDefault"] == true,
                    "vision":model["inputModalities"].as_array().map(|v| v.iter().any(|m| m == "image")).unwrap_or(true)}));
            }
            cursor = page["nextCursor"].clone();
            if cursor.is_null() {
                break;
            }
        }
        ensure!(
            !models.is_empty(),
            "O Codex nao retornou modelos. Confira a conexao e a versao instalada."
        );
        Ok(json!({"provider":"codex", "models":models}))
    }
}

async fn send(transport: &Transport, value: &Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    bytes.push(b'\n');
    let mut input = transport.input.lock().await;
    input
        .write_all(&bytes)
        .await
        .context("Nao foi possivel enviar o pedido ao Codex.")?;
    input.flush().await?;
    Ok(())
}

pub struct CancelOnDrop {
    client: Arc<Client>,
    method: &'static str,
    params: Option<Value>,
}

impl CancelOnDrop {
    pub fn new(client: Arc<Client>, method: &'static str, params: Value) -> Self {
        Self {
            client,
            method,
            params: Some(params),
        }
    }
    pub fn disarm(&mut self) {
        self.params = None;
    }
}

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if let Some(params) = self.params.take() {
            let client = self.client.clone();
            let method = self.method;
            tokio::spawn(async move {
                let _ = client.request(method, params).await;
            });
        }
    }
}

pub fn open_login(url: &str) -> Result<()> {
    let parsed = reqwest::Url::parse(url)?;
    ensure!(
        parsed.scheme() == "https"
            && matches!(
                parsed.host_str(),
                Some("auth.openai.com" | "chatgpt.com" | "auth0.openai.com")
            ),
        "O Codex retornou um endereco de login inesperado."
    );
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};
        let operation: Vec<u16> = "open\0".encode_utf16().collect();
        let address: Vec<u16> = url.encode_utf16().chain(Some(0)).collect();
        let result = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                operation.as_ptr(),
                address.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                SW_SHOWNORMAL,
            )
        };
        ensure!(
            (result as isize) > 32,
            "Nao foi possivel abrir o navegador para conectar o Codex."
        );
    }
    #[cfg(not(windows))]
    {
        let launcher = if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        };
        std::process::Command::new(launcher)
            .arg(url)
            .spawn()
            .context("Nao foi possivel abrir o navegador.")?;
    }
    Ok(())
}

pub fn connected(account: &Value) -> bool {
    account.get("account").is_some_and(|value| !value.is_null())
        || account["requiresOpenaiAuth"] == false
}

pub async fn wait_for_login(
    client: &Client,
    events: &mut broadcast::Receiver<Value>,
    login_id: &str,
) -> Result<()> {
    let wait = async {
        loop {
            let event = events
                .recv()
                .await
                .context("O Codex perdeu a conexao durante o login.")?;
            if event["method"] == "account/login/completed"
                && event["params"]["loginId"] == login_id
            {
                if event["params"]["success"] != true {
                    bail!(
                        "{}",
                        event["params"]["error"]
                            .as_str()
                            .unwrap_or("Login cancelado.")
                    );
                }
                ensure!(
                    connected(&client.account().await?),
                    "O Codex ainda nao esta conectado."
                );
                return Ok(());
            }
        }
    };
    time::timeout(Duration::from_secs(300), wait)
        .await
        .context("O tempo de login terminou. Clique em Conectar para tentar novamente.")?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellation_uses_the_exact_abandoned_turn() {
        let (method, params) = Cleanup::Turn("thread-1".into())
            .request(&json!({"turn":{"id":"turn-2"}}))
            .unwrap();
        assert_eq!(method, "turn/interrupt");
        assert_eq!(params, json!({"threadId":"thread-1", "turnId":"turn-2"}));
        assert!(
            Cleanup::Turn("thread-1".into())
                .request(&Value::Null)
                .is_none()
        );
        assert_eq!(
            Cleanup::Login
                .request(&json!({"loginId":"login-3"}))
                .unwrap()
                .1,
            json!({"loginId":"login-3"})
        );
    }

    #[test]
    fn login_does_not_open_untrusted_addresses() {
        for address in [
            "http://auth.openai.com/",
            "https://example.com/",
            "file:///C:/test",
            "https://auth.openai.com.example.com/",
        ] {
            assert!(open_login(address).is_err());
        }
    }

    #[test]
    fn account_status_distinguishes_missing_login() {
        assert!(!connected(
            &json!({"account":null, "requiresOpenaiAuth":true})
        ));
        assert!(connected(
            &json!({"account":{"type":"chatgpt"}, "requiresOpenaiAuth":true})
        ));
        assert!(connected(
            &json!({"account":null, "requiresOpenaiAuth":false})
        ));
    }
}
