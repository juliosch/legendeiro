# Legendeiro

Gera legendas em português brasileiro (`.pt-BR.srt`) para arquivos MKV. Extrai a melhor legenda disponível no vídeo e faz uma **localização** para PT-BR: linguagem natural e coloquial, gírias adaptadas e palavrões sem censura (público 18+), não uma tradução literal.

Tem dois modos de uso:

- **Claude Code (recomendado):** a skill `/legendar` usa o próprio Claude Code para localizar. Não precisa de API key e mantém nomes, gênero e tratamento consistentes ao longo da série.
- **API:** o script chama sozinho um LLM (Gemini, OpenAI, Anthropic, Groq ou Ollama) com a sua API key.

## Pré-requisitos

- **bash** 3.2+ (o do macOS serve)
- **ffmpeg** e **ffprobe**, para extrair legendas de dentro dos MKVs
- Modo API: **curl**, **jq** e uma API key do provider (exceto Ollama)

## Modo Claude Code

Com o Claude Code aberto na pasta do repo:

```
/legendar ~/Series/Minha.Serie/Season 1/
/legendar video.mkv
```

O `.pt-BR.srt` é gravado ao lado de cada MKV. Para cada arquivo, a skill:

1. Roda `./legendeiro.sh prepare`, que escolhe a melhor legenda de origem, extrai e divide em lotes `N|||texto`.
2. Escreve ou reaproveita o contexto da série em `.legendeiro-work/contexto-<serie>.md`: personagens e gênero, quem trata quem por "você" ou "a senhora", tom e glossário. É isso que mantém a temporada consistente.
3. Localiza o episódio inteiro seguindo [`.claude/skills/legendar/regras.md`](.claude/skills/legendar/regras.md). Um episódio é traduzido pela sessão principal. Numa pasta com vários episódios, cada um vai para um subagente, até 5 em paralelo.
4. Roda `./legendeiro.sh finish`, que só grava o SRT se todos os blocos estiverem traduzidos e mantém os tempos originais.

A tradução consome a cota do seu Claude Code: um episódio de uns 45 minutos tem de 700 a 900 blocos.

### Comandos usados pela skill

Os dois comandos não chamam nenhum LLM e também podem ser usados à mão:

```bash
./legendeiro.sh prepare video.mkv [--source-lang spa]   # imprime "WORKDIR: <caminho>"
./legendeiro.sh finish <WORKDIR>                        # gera video.pt-BR.srt e apaga o WORKDIR
```

- `prepare` sai com **0** (pronto), **1** (já existe PT-BR, pulado) ou **2** (erro, por exemplo vídeo sem legenda).
- O WORKDIR contém `lote_NNN.txt` (até 150 blocos cada), e as traduções vão em `lote_NNN.ptbr.txt`, no mesmo formato.
- `finish` lista os blocos que faltam, se houver, e sai com 2 sem gravar nada.
- O WORKDIR fica em `$TMPDIR` por padrão. Defina `LEGENDEIRO_WORK=<dir>` para mudar o local (a skill usa `.legendeiro-work/`, que está no `.gitignore`).
- O destino do SRT fica no arquivo `meta` do WORKDIR (`SRT_PTBR=...`). Se a pasta do vídeo não aceitar gravação, como um compartilhamento de rede só leitura, aponte para outro lugar e rode `finish` de novo.

## Modo API

```bash
./legendeiro.sh <caminho> <LLM_API_KEY> [opções]
```

| Argumento | Descrição |
|-----------|-----------|
| `caminho` | Arquivo `.mkv` ou diretório (busca recursiva) |
| `LLM_API_KEY` | API key do provider (use `none` para Ollama) |

| Opção | Descrição |
|-------|-----------|
| `--provider P` | `gemini`, `openai`, `anthropic`, `groq` ou `ollama` (padrão: `gemini`) |
| `--model M` | Modelo específico (padrão: o do provider, na tabela abaixo) |
| `--source-lang X` | Força o idioma de origem: `spa`, `eng`, `fre`... (padrão: detecta sozinho) |

```bash
./legendeiro.sh . SUA_GEMINI_KEY                                  # todos os MKVs da pasta
./legendeiro.sh "video.mkv" SUA_GEMINI_KEY                        # um arquivo
./legendeiro.sh ./series/ SUA_OPENAI_KEY --provider openai
./legendeiro.sh . none --provider ollama --model llama3.1         # local, sem key
```

| Provider | Modelo padrão | API key |
|----------|---------------|---------|
| Gemini | `gemini-2.5-flash` | [Google AI Studio](https://aistudio.google.com/apikey) |
| OpenAI | `gpt-4o-mini` | [platform.openai.com](https://platform.openai.com/api-keys) |
| Anthropic | `claude-sonnet-4-20250514` | [console.anthropic.com](https://console.anthropic.com/) |
| Groq | `llama-3.3-70b-versatile` | [console.groq.com](https://console.groq.com/keys) |
| Ollama | `llama3.1` | Nenhuma (roda local) |

> **Anthropic:** o modelo padrão está deprecated, e os modelos Claude mais novos ainda não funcionam neste modo (o script envia `temperature`, que eles recusam). Para usar Claude, prefira o modo Claude Code.

A legenda é enviada em batches de 40 blocos, com até 3 tentativas por batch. Se um batch falhar, os blocos dele ficam no idioma original. No fim de um diretório, o script mostra um resumo:

```
════════════════════════════════════════════════════════════
RESUMO
  Total:      8
  Traduzidos: 6
  Pulados:    1 (PT-BR já existia)
  Erros:      1
════════════════════════════════════════════════════════════
```

## Escolha da legenda de origem

Vale para os dois modos. O script procura primeiro um SRT externo na pasta do MKV e depois as faixas de legenda dentro do MKV, nesta ordem de idioma:

Espanhol latino > Espanhol > Português (PT) > Francês > Italiano > Romeno > Catalão > Alemão > Holandês > Russo > Polonês > Tcheco > Grego > Árabe > Inglês

- **SRT externo:** `video.<idioma>.srt`, com sufixos como `spa`, `es`, `es-419`, `latino`, `fre`, `fr`, `eng`, `en` etc. Aceita maiúsculas e minúsculas e a extensão `.SRT`.
- **Dentro do MKV:** espanhol latino é reconhecido pelo título da faixa (`Latin`, `Latino`, `LATAM`, `MX`, `México`...). Os outros idiomas, pela tag de idioma.
- **Pular arquivo:** o MKV é ignorado se já existir `video.<sufixo>.srt` com um destes sufixos: `pt-BR`, `pt-br`, `pt_BR`, `pt_br`, `ptbr`, `por.br` ou `brazilian`.

### Por que priorizar línguas românicas?

Espanhol, francês, italiano e as outras línguas românicas marcam **gênero gramatical**, e o inglês não. A partir de "the neighbor" não dá para saber se é "o vizinho" ou "a vizinha"; a partir de "el vecino" ou "la vecina", dá. Elas também compartilham cognatos e estrutura de frase com o português, o que deixa a localização mais natural. Inglês fica como último recurso.
