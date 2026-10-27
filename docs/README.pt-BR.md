# Rust Pixel Bridge

[English](../README.md) · Português

Painel de conversa dentro do Aseprite, com Codex, OpenRouter e ferramentas para criar e editar sprites. A janela usa os controles, cores e fonte do tema do editor.

## Instalação no Windows

Requisitos: Windows 10 ou 11 de 64 bits e Aseprite 1.3.15 ou superior.

1. Execute `RustPixelBridge-0.5.1-windows-x64-Setup.exe`.
2. Mantenha as pastas sugeridas. Para Aseprite portátil, selecione a pasta de configuração que contém `aseprite.ini`.
3. Reinicie o Aseprite e permita os acessos solicitados pela extensão no primeiro uso.
4. Clique no botão de modelo no rodapé do painel. Escolha **Codex** ou **OpenRouter** em **Provedor** e clique em **Conectar**. Escolha um modelo, escreva seu pedido e clique em **Enviar**.

O painel abre na primeira execução. Para reabri-lo, use **File > Scripts > Rust Pixel > Abrir painel**. No modo **Lateral**, ele fica ancorado à direita e acompanha o tamanho da janela do Aseprite. **Recolher** libera espaço sem fechar a conversa; **Livre** permite mover o painel. A API de extensões do Aseprite não oferece docking: o painel é uma janela sobreposta e não reserva uma coluna no editor.

O campo de pedido aceita várias linhas: **Enter** envia e **Shift+Enter** insere uma quebra de linha. A conversa apresenta texto formatado, agrupa as etapas de execução e mantém a posição de leitura quando você rola para mensagens anteriores. Clique em uma mensagem e use **Copiar** ou **Ctrl+C** para copiar seu texto; sem uma mensagem selecionada, **Copiar** usa a última resposta.

Use **Referência** para escolher uma imagem, conferir a prévia e clicar em **Anexar**. Ela acompanha o próximo pedido, independentemente de **Usar sprite atual**; você pode enviar ambos juntos. O **X** ao lado da miniatura remove o anexo antes do envio. O modelo precisa aceitar imagens. A referência permanece no histórico da conversa e o anexo é limpo do campo de pedido após enviar.

São aceitos PNG, JPEG, BMP, GIF e arquivos Aseprite, usando o primeiro frame. O limite é 20 MB e 16 megapixels; a cópia enviada tem até 1024 pixels no maior lado, preservando a proporção. O original não é alterado nem aberto como um novo documento. As cópias ficam localmente em `assistant\references` e só são enviadas ao provedor quando você envia o pedido.

No primeiro acesso, o Aseprite pede autorização para leitura e escrita em `bridge.lua` e para iniciar o assistente em `panel.lua`. Marque **Don't show this specific alert again for this script** antes de permitir cada tipo de acesso para que a escolha seja lembrada. **Give full trust** não é necessário. Negar o acesso interrompe a operação; o painel não fica tentando novamente em segundo plano. As permissões são sempre concedidas pelo próprio Aseprite, não pelo instalador.

**Codex:** requer o [cliente oficial Codex](https://developers.openai.com/codex/cli/) instalado. O painel detecta `codex.exe` no PATH e na instalação padrão do aplicativo; para outro local, informe o executável em **Configurar**. A conexão usa o protocolo [Codex app-server](https://developers.openai.com/codex/app-server/), reaproveita o login do cliente e abre o fluxo oficial no navegador quando necessário. Tokens não são copiados para o projeto. A integração foi validada com Codex CLI 0.164.0.

**OpenRouter:** abra **Conectar** ou **Configurar** e cole sua chave. O catálogo mostra modelos que aceitam ferramentas, incluindo fornecedores como Anthropic e Google quando disponíveis. Isso não conecta uma assinatura Claude Code ou Antigravity; esses clientes podem usar o bridge MCP externo.

Use **Buscar** para filtrar o catálogo do provedor. O modo **Agente** pode criar e editar; o modo **Perguntar** consulta o documento sem alterar os sprites. **Usar sprite atual** inclui uma prévia do documento quando o modelo aceita imagens. Trocar de provedor inicia outra conversa.

As conversas são salvas localmente. **Parar** interrompe o pedido, **Nova** começa outra conversa e **Desfazer** usa o histórico do Aseprite. Alterações já executadas permanecem disponíveis para revisão e para desfazer.

A chave é guardada no Gerenciador de Credenciais do Windows e não é incluída nas conversas ou configurações do projeto. Crie ou gerencie sua chave em [OpenRouter](https://openrouter.ai/keys). As solicitações usam os créditos e preços da sua conta.

Não é necessário instalar Rust ou manter um terminal aberto. O assistente inicia com o painel e encerra após ficar inativo.

### Pacote ZIP

Extraia `rust-pixel-0.5.1-windows-x64.zip` e execute `install.bat`. O script instala os executáveis e a extensão. Os assets e as conversas locais são mantidos ao remover a extensão com `uninstall.bat`.

### Clientes MCP

O bridge também continua disponível para clientes MCP externos. O instalador oferece configuração do Claude Desktop quando ele estiver instalado. Outros clientes podem importar o `mcp.json` gerado na pasta do programa. Nesse modo, o cliente inicia e encerra o servidor stdio automaticamente.

### Pastas padrão

| Conteúdo | Local |
| --- | --- |
| Programa e `mcp.json` | `%LOCALAPPDATA%\Programs\Rust Pixel Bridge` |
| Extensão | `%APPDATA%\Aseprite\extensions\rust-pixel` |
| Fila e biblioteca de assets | `%APPDATA%\.rust-pixel\queue` |
| Conversas e preferências do painel | `%APPDATA%\.rust-pixel\queue\assistant` |

A instalação usa a conta atual do Windows e não exige privilégios de administrador. O Aseprite é instalado separadamente e não faz parte do pacote.

## Ferramentas MCP

| Ferramenta | Função |
| --- | --- |
| `aseprite_context` | Consulta sprites abertos, camadas e paletas |
| `add_sprite` | Importa um PNG em base64 ou cria um sprite a partir de uma receita |
| `edit_sprite` | Aplica operações de desenho a um sprite aberto |
| `list_assets` | Lista os snapshots da biblioteca local |
| `get_asset_preview` | Retorna uma imagem PNG do asset |

Receitas preservam camadas e frames no Aseprite. As operações disponíveis são `put_pixel`, `rect`, `line`, `h_line`, `v_line`, `flood_fill`, `dither`, `clear` e `set_palette`. Os índices de frame começam em zero. Cores usam os campos `r`, `g`, `b` e `a`, com valores entre 0 e 255; `a` é opcional e vale 255 por padrão.

Exemplo de argumentos para `add_sprite`:

```json
{
  "name": "Tile",
  "recipe": {
    "width": 16,
    "height": 16,
    "ops": [
      { "op": "rect", "x": 2, "y": 2, "width": 12, "height": 12,
        "color": { "r": 94, "g": 170, "b": 113 } }
    ]
  }
}
```

Cada importação ou edição confirmada exporta uma cópia `.aseprite`, um PNG do primeiro frame e os metadados para a biblioteca. Para atualizar o snapshot após edições manuais, use **Exportar sprite atual**. Os arquivos originais abertos no Aseprite não são sobrescritos.

## Compilar

Com a toolchain Rust estável instalada:

```powershell
cargo build --release --bins --locked
cargo test --workspace --locked
```

No Windows, `build.bat` compila o programa e gera o instalador, o ZIP e a extensão em `dist\`. Se necessário, baixa o compilador oficial do Inno Setup e verifica sua assinatura digital. Para usar um compilador já instalado:

```powershell
.\scripts\build-windows.ps1 -IsccPath 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
```

O executável distribuído inclui o runtime C e não exige a instalação do Visual C++ Redistributable.

Para gerar somente o ZIP e a extensão, use `-SkipInstaller`. A extensão também pode ser instalada separadamente em **Edit > Preferences > Extensions**, mas o executável MCP continua necessário.

### Desenvolvimento

```powershell
cargo run -- install
cargo run -- doctor
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
```

Os testes de integração usam pastas isoladas dentro de `target\`. Com Node.js instalado, `node scripts/test-install.mjs` verifica a instalação e a preservação das configurações existentes. Para validar a extensão com uma instalação local do Aseprite:

```powershell
.\scripts\test-aseprite.ps1 -AsepritePath 'C:\caminho\Aseprite.exe'
node scripts/test-mcp.mjs target/release/asprite-mcp.exe 'C:\caminho\Aseprite.exe'
node scripts/test-assistant.mjs target/release/rust-pixel-agent.exe 'C:\caminho\Aseprite.exe'
node scripts/test-codex.mjs target/release/rust-pixel-agent.exe 'C:\caminho\Aseprite.exe'
```

Os testes do assistente usam uma API local e um app-server simulado para validar ferramentas, streaming, histórico, cancelamento e desenho no Aseprite, sem inferência paga. `node scripts/check-codex.mjs` consulta apenas o catálogo do cliente Codex instalado, sem iniciar login nem enviar pedidos de geração.

`scripts/test-installer.ps1` verifica o Setup e sua desinstalação. Execute esse teste em um perfil Windows sem uma instalação anterior do Rust Pixel Bridge.

`asprite-mcp --help` lista as opções de instalação. `--aseprite-dir` recebe a pasta de configuração, não a pasta do executável do Aseprite. `RUST_PIXEL_QUEUE_DIR` permite definir outra fila; a extensão e o servidor devem usar o mesmo caminho.

O transporte MCP é stdio e os logs são enviados para stderr. A extensão e o assistente trocam arquivos localmente. OpenRouter usa HTTPS; Codex usa um processo app-server local por stdio e deixa a autenticação e a inferência a cargo do cliente oficial. O login Codex pode abrir um callback local temporário, administrado pelo próprio cliente.

No Codex, o painel desativa shell, delegação, pesquisa e conexões MCP alheias ao bridge nessa instância, sem editar a configuração global do cliente. Apenas as ferramentas de desenho são atendidas pelo painel. A extensão recebe comandos somente enquanto o Aseprite está aberto e o bridge está ativado.

## Solução de problemas

- **Aseprite offline:** abra o editor, habilite o bridge no menu Rust Pixel e permita o acesso a arquivos solicitado pela extensão.
- **Codex não encontrado:** confira a instalação do cliente oficial ou informe o caminho completo de `codex.exe` em **Configurar**.
- **Codex desconectado:** clique em **Conectar** e conclua o login no navegador. Para mudar de conta, use o cliente Codex.
- **OpenRouter não conecta:** confira a chave em **Configurar**, a conexão de rede e os créditos da conta.
- **Extensão não aparece:** confira a pasta de configuração selecionada e reinicie o Aseprite.
- **Cliente não encontra o servidor:** confira o caminho de `command` em `mcp.json` e reinicie o cliente.
- **Configuração inválida do cliente:** corrija o JSON indicado no erro e execute a instalação novamente. As configurações existentes recebem backup antes de qualquer atualização.
- **Verificar conexão:** use o atalho **Verificar conexão** do menu Iniciar ou execute `asprite-mcp doctor`.

## Licença

[MIT](../LICENSE).
