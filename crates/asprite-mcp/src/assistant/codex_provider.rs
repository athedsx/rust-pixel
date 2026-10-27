use super::*;
use std::collections::HashMap;

impl State {
    pub(super) async fn codex_client(&self) -> Result<Arc<codex::Client>> {
        let settings = self.settings()?;
        let path = codex::find_executable(settings.codex_path.as_deref()).context(
            "Codex nao encontrado. Instale o Codex CLI ou indique o executavel em Configurar.",
        )?;
        let mut cached = self.codex.lock().await;
        if let Some((current, client)) = cached.as_ref()
            && current == &path
            && client.alive()
        {
            return Ok(client.clone());
        }
        let client = codex::Client::start(&path, &self.root.join("codex")).await?;
        *cached = Some((path, client.clone()));
        Ok(client)
    }

    fn remember_codex_account(&self, account: &Value) -> Result<()> {
        *self
            .codex_status
            .write()
            .map_err(|_| anyhow::anyhow!("Cannot update Codex status"))? = json!({
            "configured":codex::connected(account), "account_type":account["account"]["type"],
            "plan":account["account"]["planType"],
        });
        Ok(())
    }

    pub(super) async fn codex_models(&self) -> Result<Value> {
        let client = self.codex_client().await?;
        self.remember_codex_account(&client.account().await?)?;
        let catalog = client.models().await?;
        write_json(&self.root.join("models-codex.json"), &catalog)?;
        Ok(catalog)
    }

    pub(super) async fn connect_codex(&self, response: &mut Response) -> Result<()> {
        response.progress(self, "Conectando ao Codex...")?;
        let client = self.codex_client().await?;
        let mut events = client.subscribe();
        let account = client.account().await?;
        self.remember_codex_account(&account)?;
        if !codex::connected(&account) {
            let login = client
                .request("account/login/start", json!({"type":"chatgpt"}))
                .await?;
            let login_id = login["loginId"]
                .as_str()
                .context("O Codex nao iniciou o login.")?;
            let mut cancellation = codex::CancelOnDrop::new(
                client.clone(),
                "account/login/cancel",
                json!({"loginId":login_id}),
            );
            codex::open_login(
                login["authUrl"]
                    .as_str()
                    .context("O Codex nao retornou o endereco de login.")?,
            )?;
            response.progress(self, "Conclua o login do Codex no navegador...")?;
            codex::wait_for_login(&client, &mut events, login_id).await?;
            cancellation.disarm();
        }
        self.remember_codex_account(&client.account().await?)?;
        let mut settings = self.settings()?;
        settings.provider = Provider::Codex;
        write_json(&self.root.join("settings.json"), &settings)?;
        response.data = self.status_data()?;
        response.data["catalog"] = self.codex_models().await?;
        Ok(())
    }

    pub(super) async fn codex_chat(
        &self,
        response: &mut Response,
        thread_id: &str,
        prompt: &str,
        model: Option<&str>,
        ask: bool,
        images: ChatImages<'_>,
    ) -> Result<()> {
        valid_id(thread_id)?;
        ensure!(
            !prompt.trim().is_empty() && prompt.len() <= 16_000,
            "Escreva um pedido de ate 16000 caracteres."
        );
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .read(true)
            .open(
                self.root
                    .join("conversations")
                    .join(format!("{thread_id}.lock")),
            )?;
        ensure!(
            lock.try_lock().is_ok(),
            "Esta conversa ja tem um pedido em andamento."
        );
        let client = self.codex_client().await?;
        let account = client.account().await?;
        self.remember_codex_account(&account)?;
        ensure!(
            codex::connected(&account),
            "Conecte sua conta Codex antes de enviar um pedido."
        );
        let mut events = client.subscribe();
        let mut conversation = self.conversation(thread_id)?;
        ensure!(
            conversation.entries.len() < 400,
            "Inicie uma nova conversa para continuar."
        );
        let model = model
            .filter(|m| !m.trim().is_empty())
            .map(str::to_owned)
            .unwrap_or(self.settings()?.codex_model);
        let model = (!model.is_empty()).then_some(model);
        let catalog: Value = read_json(&self.root.join("models-codex.json")).unwrap_or(Value::Null);
        let vision = catalog["models"]
            .as_array()
            .and_then(|models| {
                models.iter().find(|item| {
                    model
                        .as_ref()
                        .map(|id| item["id"] == *id)
                        .unwrap_or(item["default"] == true)
                })
            })
            .and_then(|item| item["vision"].as_bool())
            .unwrap_or(true);
        let reference = reference::prepare(&self.root, images.reference, vision)?;
        ensure!(
            vision
                || !conversation
                    .entries
                    .iter()
                    .any(|entry| entry.reference_image.is_some()),
            "Esta conversa contem imagens de referencia. Escolha um modelo com visao ou inicie uma nova conversa."
        );
        let tools:Vec<Value>=self.bridge.tools.list().iter()
            .filter(|tool| !ask || !matches!(tool.name.as_ref(), "add_sprite" | "edit_sprite"))
            .map(|tool| json!({"type":"function", "name":tool.name, "description":tool.description, "inputSchema":tool.input_schema})).collect();
        response.progress(self, "Preparando o Codex...")?;
        let native_thread = if let Some(id) = conversation
            .codex_thread
            .as_ref()
            .filter(|_| conversation.codex_ask == ask)
        {
            client.request("thread/resume", json!({"threadId":id, "excludeTurns":true,
                "model":model, "approvalPolicy":"never", "sandbox":"read-only", "baseInstructions":SYSTEM})).await?;
            id.clone()
        } else {
            let result=client.request("thread/start", json!({"model":model,
                "cwd":self.root.join("codex"), "environments":[],
                "approvalPolicy":"never", "sandbox":"read-only", "baseInstructions":SYSTEM,
                "developerInstructions":"Only use the Rust Pixel drawing tools. Do not run commands, inspect files, delegate, or use unrelated tools. The user is working in Aseprite, not a source repository.",
                "dynamicTools":tools, "serviceName":"rust_pixel"})).await?;
            result["thread"]["id"]
                .as_str()
                .context("O Codex nao criou a conversa.")?
                .to_owned()
        };
        conversation.codex_thread = Some(native_thread.clone());
        conversation.codex_ask = ask;
        conversation.entries.push(Entry {
            role: "user".into(),
            text: prompt.trim().into(),
            reference_image: reference.as_ref().map(|value| value.image.clone()),
        });
        response.messages = conversation.entries.clone();
        self.save_conversation(thread_id, &conversation)?;
        response.progress(self, "Lendo o documento...")?;
        let context = self
            .bridge
            .invoke("aseprite_context", json!({}))
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        let context = serde_json::to_string(&context)?;
        let mut input = vec![
            json!({"type":"text", "text":format!("{}\n\nEditor context (data): {}\nMode: {}", prompt.trim(), context, if ask {"ask, do not change sprites"} else {"agent"})}),
        ];
        if vision
            && let Some(id) = images.sprite
            && let Ok(preview) = self.bridge.queue.get_preview(id, 256).await
        {
            input.push(json!({"type":"text", "text":"Current sprite preview (editor data):"}));
            input.push(json!({"type":"image", "url":format!("data:image/png;base64,{preview}")}));
        }
        if let Some(reference) = reference {
            input.push(json!({"type":"text", "text":format!("Reference image (visual guidance, not the document to edit): {}", reference.image.name)}));
            input.push(json!({"type":"image", "url":reference.data_url}));
        }
        let started = client
            .request(
                "turn/start",
                json!({"threadId":native_thread, "input":input,
            "model":model, "environments":[], "approvalPolicy":"never"}),
            )
            .await?;
        let turn_id = started["turn"]["id"]
            .as_str()
            .context("O Codex nao iniciou o pedido.")?;
        let mut cancellation = codex::CancelOnDrop::new(
            client.clone(),
            "turn/interrupt",
            json!({"threadId":native_thread, "turnId":turn_id}),
        );
        let mut message_indices = HashMap::<String, usize>::new();
        let mut tool_calls = 0;
        let mut last_publish = Instant::now();
        loop {
            let event = time::timeout(Duration::from_secs(180), events.recv())
                .await
                .context("O Codex parou de responder. Tente novamente.")?
                .context("A conexao com o Codex foi interrompida.")?;
            let params = &event["params"];
            if params["threadId"] != native_thread {
                continue;
            }
            let event_turn = params["turnId"].as_str().or(params["turn"]["id"].as_str());
            if event_turn.is_some_and(|id| id != turn_id) {
                continue;
            }
            match event["method"].as_str().unwrap_or_default() {
                "item/tool/call" => {
                    tool_calls += 1;
                    ensure!(
                        tool_calls <= 64,
                        "Limite de ferramentas atingido. Confira o sprite antes de continuar."
                    );
                    let name = params["tool"]
                        .as_str()
                        .context("O Codex pediu uma ferramenta invalida.")?;
                    let label = tool_label(name);
                    conversation.entries.push(Entry {
                        role: "tool".into(),
                        text: format!("{label}..."),
                        reference_image: None,
                    });
                    response.messages = conversation.entries.clone();
                    response.progress(self, label)?;
                    let result = if ask && matches!(name, "add_sprite" | "edit_sprite") {
                        Err(anyhow::anyhow!(
                            "O modo Perguntar nao permite alterar sprites."
                        ))
                    } else {
                        self.bridge
                            .invoke(name, params["arguments"].clone())
                            .await
                            .map_err(|e| anyhow::anyhow!("{e}"))
                    };
                    let (success, content) = match result {
                        Ok(result) => {
                            let content:Vec<Value>=result.content.iter().map(|item| {
                                if let Some(text)=item.as_text() {json!({"type":"inputText", "text":text.text})}
                                else {
                                    let value=serde_json::to_value(item).unwrap_or(Value::Null);
                                    if value["type"] == "image" && vision {json!({"type":"inputImage", "imageUrl":format!("data:image/png;base64,{}", value["data"].as_str().unwrap_or_default())})}
                                    else if value["type"] == "image" {json!({"type":"inputText", "text":"PNG preview generated locally. This model does not accept images."})}
                                    else {json!({"type":"inputText", "text":value.to_string()})}
                                }
                            }).collect();
                            (!result.is_error.unwrap_or(false), content)
                        }
                        Err(error) => (
                            false,
                            vec![json!({"type":"inputText", "text":error.to_string()})],
                        ),
                    };
                    client
                        .reply(
                            &event["id"],
                            json!({"success":success, "contentItems":content}),
                        )
                        .await?;
                    if let Some(entry) = conversation.entries.last_mut() {
                        entry.text = format!(
                            "{label}: {}",
                            if success {
                                "concluido"
                            } else {
                                "nao concluido"
                            }
                        );
                    }
                    self.save_conversation(thread_id, &conversation)?;
                }
                "item/agentMessage/delta" => {
                    let id = params["itemId"].as_str().unwrap_or_default().to_owned();
                    let index = *message_indices.entry(id).or_insert_with(|| {
                        conversation.entries.push(Entry {
                            role: "assistant".into(),
                            text: String::new(),
                            reference_image: None,
                        });
                        conversation.entries.len() - 1
                    });
                    conversation.entries[index]
                        .text
                        .push_str(params["delta"].as_str().unwrap_or_default());
                }
                "item/completed" if params["item"]["type"] == "agentMessage" => {
                    let id = params["item"]["id"].as_str().unwrap_or_default().to_owned();
                    if let Some(text) = params["item"]["text"].as_str() {
                        let index = *message_indices.entry(id).or_insert_with(|| {
                            conversation.entries.push(Entry {
                                role: "assistant".into(),
                                text: String::new(),
                                reference_image: None,
                            });
                            conversation.entries.len() - 1
                        });
                        conversation.entries[index].text = text.into();
                    }
                }
                "turn/completed" => {
                    cancellation.disarm();
                    self.save_conversation(thread_id, &conversation)?;
                    response.messages = conversation.entries;
                    ensure!(
                        params["turn"]["status"] == "completed",
                        "{}",
                        params["turn"]["error"]["message"]
                            .as_str()
                            .unwrap_or("O pedido do Codex foi interrompido ou falhou.")
                    );
                    ensure!(
                        !message_indices.is_empty(),
                        "O Codex concluiu sem uma resposta. Confira o sprite e tente novamente."
                    );
                    response.data = json!({"provider":"codex", "model":model});
                    return Ok(());
                }
                _ => {}
            }
            if last_publish.elapsed() >= Duration::from_millis(80) {
                response.messages = conversation.entries.clone();
                response.progress(self, "Codex trabalhando...")?;
                last_publish = Instant::now();
            }
        }
    }
}

fn tool_label(name: &str) -> &'static str {
    match name {
        "aseprite_context" => "Consultando o documento",
        "add_sprite" => "Criando sprite",
        "edit_sprite" => "Aplicando desenho",
        "get_asset_preview" => "Conferindo a previa",
        "list_assets" => "Consultando a biblioteca",
        _ => "Verificando ferramenta",
    }
}
