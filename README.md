# Legendeiro

Script bash para extrair legendas de arquivos MKV e localizá-las para português brasileiro (PT-BR) usando LLMs.

O Legendeiro prioriza legendas em línguas românicas (espanhol, francês, italiano, etc.) como fonte de tradução, pois essas línguas preservam gênero gramatical e têm proximidade lexical com o português — o que resulta em uma localização mais precisa. Inglês é usado como fallback quando nenhuma língua românica está disponível.

## Como funciona

1. **Busca arquivos MKV** no caminho informado (arquivo único ou diretório recursivo)
2. **Pula arquivos** que já possuem legenda `.pt-BR.srt`
3. **Detecta a melhor legenda disponível**, procurando primeiro por arquivos SRT externos e depois dentro do MKV, seguindo esta ordem de prioridade:
   - Espanhol latino > Espanhol > Português (PT) > Francês > Italiano > Romeno > Catalão > Alemão > Holandês > Russo > Polonês > Tcheco > Grego > Árabe > Inglês
4. **Busca contexto da série no OMDB** (sinopse, elenco, gênero, info do episódio) para alimentar o LLM com contexto
5. **Localiza as legendas** via LLM em batches, gerando um arquivo `.pt-BR.srt` ao lado do MKV original

O prompt enviado ao LLM instrui uma **localização** (não apenas tradução literal), com linguagem coloquial brasileira e sem censura de palavrões (público 18+).

## Pré-requisitos

- **bash** 3.2+
- **ffmpeg** e **ffprobe** (para extrair legendas dos MKVs)
- **jq** (para montar/parsear JSON)
- **curl**
- Uma chave de API de LLM (ver [Providers suportados](#providers-suportados))
- Uma chave de API do [OMDB](https://www.omdbapi.com/apikey.aspx) (gratuita, 1000 requests/dia)

## Uso

```bash
./translate-srt.sh <caminho> <LLM_API_KEY> <OMDB_API_KEY> [opções]
```

| Argumento | Descrição |
|-----------|-----------|
| `caminho` | Arquivo `.mkv` ou diretório (busca recursiva) |
| `LLM_API_KEY` | Chave da API do LLM (use `none` para Ollama) |
| `OMDB_API_KEY` | Chave da API do OMDB |

### Opções

| Flag | Descrição |
|------|-----------|
| `--provider P` | Provider do LLM: `gemini`, `openai`, `anthropic`, `groq`, `ollama` (padrão: `gemini`) |
| `--model M` | Modelo específico (se omitido, usa o padrão do provider) |
| `--series "Nome"` | Nome da série para busca no OMDB (se omitido, extrai do nome do arquivo) |
| `--source-lang X` | Forçar idioma de origem: `spa`, `eng`, `fre`, etc. (se omitido, auto-detecta) |

### Exemplos

```bash
# Traduzir todos os MKVs do diretório atual
./translate-srt.sh . SUA_GEMINI_KEY SUA_OMDB_KEY

# Traduzir um arquivo específico
./translate-srt.sh "video.mkv" SUA_GEMINI_KEY SUA_OMDB_KEY

# Usar OpenAI
./translate-srt.sh ./series/ SUA_OPENAI_KEY SUA_OMDB_KEY --provider openai

# Usar Claude
./translate-srt.sh . SUA_ANTHROPIC_KEY SUA_OMDB_KEY --provider anthropic

# Usar Ollama (local, sem API key)
./translate-srt.sh . none SUA_OMDB_KEY --provider ollama --model llama3.1

# Forçar nome da série (útil quando o nome do arquivo é confuso)
./translate-srt.sh . SUA_KEY SUA_OMDB_KEY --series "The 'Burbs"
```

## Providers suportados

| Provider | Modelo padrão | API Key |
|----------|--------------|---------|
| Gemini | `gemini-2.5-flash` | [Google AI Studio](https://aistudio.google.com/apikey) |
| OpenAI | `gpt-4o-mini` | [platform.openai.com](https://platform.openai.com/api-keys) |
| Anthropic | `claude-sonnet-4-20250514` | [console.anthropic.com](https://console.anthropic.com/) |
| Groq | `llama-3.3-70b-versatile` | [console.groq.com](https://console.groq.com/keys) |
| Ollama | `llama3.1` | Nenhuma (roda local) |

## Detecção de legendas

O script busca legendas em duas fontes, nesta ordem:

### 1. Arquivos SRT externos

Procura na mesma pasta do MKV por arquivos com sufixos como:

- `video.spa.srt`, `video.es.srt`, `video.spanish.srt`
- `video.es-LA.srt`, `video.latino.srt`, `video.es-419.srt`
- `video.fre.srt`, `video.fr.srt`
- `video.eng.srt`, `video.en.srt`
- etc.

### 2. Streams dentro do MKV

Extrai via `ffprobe`/`ffmpeg`, priorizando streams com título indicando espanhol latino (`Latin`, `Latino`, `LATAM`, `MX`).

### Skip automático

Se já existir um arquivo com qualquer um destes padrões, o script pula o arquivo:

`video.pt-BR.srt`, `video.pt_BR.srt`, `video.ptbr.srt`, `video.brazilian.srt`

## Por que priorizar línguas românicas?

Línguas da mesma família (espanhol, francês, italiano, português de Portugal, romeno, catalão) preservam **gênero gramatical** — algo que o inglês não faz. Quando o LLM traduz "the neighbor" do inglês, não sabe se deve usar "o vizinho" ou "a vizinha". Mas a partir de "el vecino" ou "la vecina" do espanhol, a tradução é inequívoca.

Além disso, línguas românicas compartilham cognatos e estruturas frasais que resultam em uma localização mais natural.

## Saída

O script gera um arquivo `.pt-BR.srt` no mesmo diretório do MKV original. Ao processar um diretório, exibe um resumo ao final:

```
════════════════════════════════════════════════════════════
RESUMO
  Total:      8
  Traduzidos: 6
  Pulados:    1 (PT-BR já existia)
  Erros:      1
════════════════════════════════════════════════════════════
```
