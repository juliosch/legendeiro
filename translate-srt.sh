#!/usr/bin/env bash
set -euo pipefail

# ─── Configuração ───────────────────────────────────────────────
BATCH_SIZE=40        # blocos SRT por request
# ────────────────────────────────────────────────────────────────

# ─── Modelos padrão por provider ────────────────────────────────
default_model_for() {
  case "$1" in
    gemini)    echo "gemini-2.5-flash" ;;
    openai)    echo "gpt-4o-mini" ;;
    anthropic) echo "claude-sonnet-4-20250514" ;;
    groq)      echo "llama-3.3-70b-versatile" ;;
    ollama)    echo "llama3.1" ;;
    *) echo "" ;;
  esac
}

usage() {
  cat <<EOF
Uso: $0 <caminho> <LLM_API_KEY> <OMDB_API_KEY> [opções]

  caminho        - Arquivo MKV ou diretório (busca recursiva por .mkv)
  LLM_API_KEY    - Chave de API do LLM (use "none" para ollama)
  OMDB_API_KEY   - Chave de API do OMDB (grátis em omdbapi.com)

Opções:
  --provider P     - Provider do LLM (padrão: gemini)
                     Opções: gemini, openai, anthropic, groq, ollama
  --model M        - Modelo específico (se omitido, usa o padrão do provider)
  --series "Nome"  - Nome da série (se omitido, extrai do nome do arquivo)
  --source-lang X  - Idioma de origem: spa, eng, etc (padrão: auto-detecta)

Providers e modelos padrão:
  gemini     →  $(default_model_for gemini)
  openai     →  $(default_model_for openai)
  anthropic  →  $(default_model_for anthropic)
  groq       →  $(default_model_for groq)
  ollama     →  $(default_model_for ollama)

Exemplos:
  $0 ./videos/ GEMINI_KEY OMDB_KEY
  $0 video.mkv GEMINI_KEY OMDB_KEY
  $0 ./series/ OPENAI_KEY OMDB_KEY --provider openai
  $0 . none OMDB_KEY --provider ollama --model llama3.1
EOF
  exit 1
}

# ─── Parsear argumentos ─────────────────────────────────────────
[[ $# -lt 3 ]] && usage

INPUT_PATH="$1"
LLM_KEY="$2"
OMDB_KEY="$3"
shift 3

PROVIDER="gemini"
MODEL=""
ARG_SERIES_NAME=""
ARG_SOURCE_LANG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      PROVIDER="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --series)
      ARG_SERIES_NAME="$2"
      shift 2
      ;;
    --source-lang)
      ARG_SOURCE_LANG="$2"
      shift 2
      ;;
    *)
      echo "Opção desconhecida: $1"
      usage
      ;;
  esac
done

# Validar provider
case "$PROVIDER" in
  gemini|openai|anthropic|groq|ollama) ;;
  *)
    echo "Erro: provider '$PROVIDER' não suportado."
    echo "Opções: gemini, openai, anthropic, groq, ollama"
    exit 1
    ;;
esac

# Definir modelo se não especificado
if [[ -z "$MODEL" ]]; then
  MODEL=$(default_model_for "$PROVIDER")
fi

# Validar input
if [[ ! -f "$INPUT_PATH" && ! -d "$INPUT_PATH" ]]; then
  echo "Erro: '$INPUT_PATH' não encontrado."
  exit 1
fi

echo "Provider: $PROVIDER | Modelo: $MODEL"
echo ""

# ─── Contadores globais ─────────────────────────────────────────
COUNT_TOTAL=0
COUNT_TRANSLATED=0
COUNT_SKIPPED=0
COUNT_ERRORS=0

# ─── Mapa de idiomas ────────────────────────────────────────────
get_lang_name() {
  case "$1" in
    spa-lat) echo "espanhol latino" ;;
    spa) echo "espanhol" ;;
    eng) echo "inglês" ;;
    fre) echo "francês" ;;
    ger) echo "alemão" ;;
    ita) echo "italiano" ;;
    por) echo "português" ;;
    ron|rum) echo "romeno" ;;
    cat) echo "catalão" ;;
    dut|nld) echo "holandês" ;;
    rus) echo "russo" ;;
    pol) echo "polonês" ;;
    cze|ces) echo "tcheco" ;;
    gre|ell) echo "grego" ;;
    ara) echo "árabe" ;;
    heb) echo "hebraico" ;;
    jpn) echo "japonês" ;;
    kor) echo "coreano" ;;
    chi|zho) echo "chinês" ;;
    tur) echo "turco" ;;
    *) echo "$1" ;;
  esac
}

# ─── Função genérica de chamada LLM ─────────────────────────────
call_llm() {
  local prompt="$1"
  local response=""

  case "$PROVIDER" in
    gemini)
      local payload
      payload=$(jq -n --arg text "$prompt" '{
        "contents": [{"parts": [{"text": $text}]}],
        "generationConfig": {"temperature": 0.3}
      }')

      response=$(curl -s -X POST \
        "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${LLM_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

      local err
      err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
      if [[ -n "$err" ]]; then
        echo "ERRO:$err"
        return 1
      fi

      echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null
      ;;

    openai|groq)
      local api_url
      if [[ "$PROVIDER" == "openai" ]]; then
        api_url="https://api.openai.com/v1/chat/completions"
      else
        api_url="https://api.groq.com/openai/v1/chat/completions"
      fi

      local payload
      payload=$(jq -n --arg model "$MODEL" --arg prompt "$prompt" '{
        "model": $model,
        "messages": [{"role": "user", "content": $prompt}],
        "temperature": 0.3
      }')

      response=$(curl -s -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${LLM_KEY}" \
        -d "$payload" 2>&1)

      local err
      err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
      if [[ -n "$err" ]]; then
        echo "ERRO:$err"
        return 1
      fi

      echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null
      ;;

    anthropic)
      local payload
      payload=$(jq -n --arg model "$MODEL" --arg prompt "$prompt" '{
        "model": $model,
        "max_tokens": 8192,
        "messages": [{"role": "user", "content": $prompt}],
        "temperature": 0.3
      }')

      response=$(curl -s -X POST "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${LLM_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -d "$payload" 2>&1)

      local err_type
      err_type=$(echo "$response" | jq -r '.error.type // empty' 2>/dev/null)
      if [[ -n "$err_type" ]]; then
        local err_msg
        err_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
        echo "ERRO:$err_msg"
        return 1
      fi

      echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null
      ;;

    ollama)
      local payload
      payload=$(jq -n --arg model "$MODEL" --arg prompt "$prompt" '{
        "model": $model,
        "prompt": $prompt,
        "stream": false,
        "options": {"temperature": 0.3}
      }')

      response=$(curl -s -X POST "http://localhost:11434/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

      local err
      err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
      if [[ -n "$err" ]]; then
        echo "ERRO:$err"
        return 1
      fi

      echo "$response" | jq -r '.response // empty' 2>/dev/null
      ;;
  esac
}

# ─── Extrair nome da série do arquivo ────────────────────────────
extract_series_name() {
  local filename
  filename="$(basename "$1")"
  filename="${filename%.*}"

  local name
  if [[ "$filename" =~ ^(.+)[.\ ][Ss][0-9]+[Ee][0-9]+ ]]; then
    name="${BASH_REMATCH[1]}"
  elif [[ "$filename" =~ ^(.+)[.\ ][0-9]+[xX][0-9]+ ]]; then
    name="${BASH_REMATCH[1]}"
  else
    name=$(echo "$filename" | sed -E 's/[. ](19|20)[0-9]{2}.*//')
  fi

  name="${name//\./ }"
  name="${name//_/ }"
  name=$(echo "$name" | sed -E 's/ *(19|20)[0-9]{2} *$//')
  name=$(echo "$name" | sed 's/  */ /g; s/^ *//; s/ *$//')

  echo "$name"
}

# ─── Sufixos SRT por idioma ─────────────────────────────────────
get_srt_suffixes() {
  case "$1" in
    spa-lat) echo "es-LA es-419 es-MX es-la es-mx lat latino spa-lat spanish-latin espanhol-latino" ;;
    spa) echo "spa es spanish espanhol es-ES spa-cas castellano castilian" ;;
    por) echo "por pt portuguese portugues" ;;
    fre) echo "fre fr french francais" ;;
    ita) echo "ita it italian italiano" ;;
    ron) echo "ron ro rum romanian romeno" ;;
    cat) echo "cat ca catalan catalao" ;;
    ger) echo "ger de deu german deutsch alemao" ;;
    dut) echo "dut nl nld dutch nederlands holandes" ;;
    rus) echo "rus ru russian russo" ;;
    pol) echo "pol pl polish polones" ;;
    cze) echo "cze cs ces czech tcheco" ;;
    gre) echo "gre el ell greek grego" ;;
    ara) echo "ara ar arabic arabe" ;;
    eng) echo "eng en english ingles" ;;
    *) echo "$1" ;;
  esac
}

# ─── Buscar SRT externo ─────────────────────────────────────────
find_external_srt() {
  local mkv_dir="$1"
  local basename="$2"
  local lang_code="$3"
  local patterns
  patterns=$(get_srt_suffixes "$lang_code")

  for suffix in $patterns; do
    local upper_suffix
    upper_suffix=$(echo "$suffix" | tr '[:lower:]' '[:upper:]')
    for candidate in "${mkv_dir}/${basename}.${suffix}.srt" \
                     "${mkv_dir}/${basename}.${suffix}.SRT" \
                     "${mkv_dir}/${basename}.${upper_suffix}.srt" \
                     "${mkv_dir}/${basename}.${upper_suffix}.SRT"; do
      if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
  done
  return 1
}

# ─── Buscar contexto no OMDB ────────────────────────────────────
# Cache: evita buscar a mesma série múltiplas vezes
OMDB_CACHE_SERIES=""
OMDB_CACHE_CONTEXT=""

fetch_omdb_context() {
  local search_name="$1"
  local season="${2:-}"
  local episode="${3:-}"

  # Se já buscou essa série, usar cache (só atualiza episódio)
  if [[ "$search_name" == "$OMDB_CACHE_SERIES" && -n "$OMDB_CACHE_CONTEXT" ]]; then
    SERIES_CONTEXT="$OMDB_CACHE_CONTEXT"
    # Buscar info do episódio se mudou
    if [[ -n "$season" && -n "$episode" ]]; then
      local title
      title=$(echo "$SERIES_CONTEXT" | head -1 | sed 's/.*"\(.*\)".*/\1/')
      local ep_response
      ep_response=$(curl -s "https://www.omdbapi.com/?t=$(jq -rn --arg s "$title" '$s|@uri')&Season=${season}&Episode=${episode}&apikey=${OMDB_KEY}" 2>/dev/null)
      local ep_title
      ep_title=$(echo "$ep_response" | jq -r '.Title // empty' 2>/dev/null)
      local ep_plot
      ep_plot=$(echo "$ep_response" | jq -r '.Plot // empty' 2>/dev/null)
      if [[ -n "$ep_title" && "$ep_title" != "null" ]]; then
        echo "  Episódio: S${season}E${episode} - $ep_title"
      fi
      # Remover episódio anterior do contexto e adicionar o novo
      SERIES_CONTEXT=$(echo "$SERIES_CONTEXT" | grep -v "^Episódio atual")
      if [[ -n "$ep_plot" && "$ep_plot" != "N/A" && "$ep_plot" != "null" ]]; then
        SERIES_CONTEXT="${SERIES_CONTEXT}
Episódio atual (S${season}E${episode}): ${ep_plot}"
      fi
    fi
    return 0
  fi

  local encoded_name
  encoded_name=$(jq -rn --arg s "$search_name" '$s|@uri')

  local series_response
  series_response=$(curl -s "https://www.omdbapi.com/?t=${encoded_name}&type=series&apikey=${OMDB_KEY}" 2>/dev/null)

  local omdb_response
  omdb_response=$(echo "$series_response" | jq -r '.Response // "False"' 2>/dev/null)

  if [[ "$omdb_response" != "True" ]]; then
    echo "  Busca por título exato falhou. Tentando busca por pesquisa..." >&2
    local search_results
    search_results=$(curl -s "https://www.omdbapi.com/?s=${encoded_name}&type=series&apikey=${OMDB_KEY}" 2>/dev/null)
    local first_id
    first_id=$(echo "$search_results" | jq -r '.Search[0].imdbID // empty' 2>/dev/null)
    if [[ -z "$first_id" ]]; then
      echo "  Aviso: série \"${search_name}\" não encontrada no OMDB." >&2
      return 1
    fi
    series_response=$(curl -s "https://www.omdbapi.com/?i=${first_id}&plot=full&apikey=${OMDB_KEY}" 2>/dev/null)
  fi

  local title genre plot actors
  title=$(echo "$series_response" | jq -r '.Title // empty')
  genre=$(echo "$series_response" | jq -r '.Genre // empty')
  plot=$(echo "$series_response" | jq -r '.Plot // empty')
  actors=$(echo "$series_response" | jq -r '.Actors // empty')

  echo "  Série encontrada: $title"
  echo "  Gênero: $genre"

  SERIES_CONTEXT="CONTEXTO DA SÉRIE:
\"${title}\" é uma série de ${genre}.
Sinopse: ${plot}
Elenco principal: ${actors}"

  # Cache da série
  OMDB_CACHE_SERIES="$search_name"
  OMDB_CACHE_CONTEXT="$SERIES_CONTEXT"

  # Buscar episódio
  if [[ -n "$season" && -n "$episode" ]]; then
    local ep_response
    ep_response=$(curl -s "https://www.omdbapi.com/?t=$(jq -rn --arg s "$title" '$s|@uri')&Season=${season}&Episode=${episode}&apikey=${OMDB_KEY}" 2>/dev/null)
    local ep_title
    ep_title=$(echo "$ep_response" | jq -r '.Title // empty' 2>/dev/null)
    local ep_plot
    ep_plot=$(echo "$ep_response" | jq -r '.Plot // empty' 2>/dev/null)
    if [[ -n "$ep_title" && "$ep_title" != "null" ]]; then
      echo "  Episódio: S${season}E${episode} - $ep_title"
    fi
    if [[ -n "$ep_plot" && "$ep_plot" != "N/A" && "$ep_plot" != "null" ]]; then
      SERIES_CONTEXT="${SERIES_CONTEXT}
Episódio atual (S${season}E${episode}): ${ep_plot}"
    fi
  fi

  return 0
}

# ─── Prioridade de idiomas ──────────────────────────────────────
LANG_PRIORITY=(spa-lat spa por fre ita ron cat ger dut rus pol cze gre ara eng)

# ════════════════════════════════════════════════════════════════
# ─── PROCESSAR UM ARQUIVO MKV ──────────────────────────────────
# ════════════════════════════════════════════════════════════════
process_file() {
  local mkv_file="$1"
  local basename
  basename="$(basename "${mkv_file%.*}")"
  local mkv_dir
  mkv_dir="$(dirname "$mkv_file")"
  local srt_ptbr="${mkv_file%.*}.pt-BR.srt"

  # ── Checar se já existe PT-BR ──
  local ptbr_patterns="pt-BR pt-br pt_BR pt_br ptbr por.br brazilian"
  for suffix in $ptbr_patterns; do
    for candidate in "${mkv_dir}/${basename}.${suffix}.srt" "${mkv_dir}/${basename}.${suffix}.SRT"; do
      if [[ -f "$candidate" ]]; then
        echo "  SKIP: PT-BR já existe ($candidate)"
        return 1
      fi
    done
  done
  if [[ -f "$srt_ptbr" ]]; then
    echo "  SKIP: PT-BR já existe ($srt_ptbr)"
    return 1
  fi

  # ── Detectar série e episódio ──
  local series_name="$ARG_SERIES_NAME"
  if [[ -z "$series_name" ]]; then
    series_name=$(extract_series_name "$mkv_file")
  fi

  local season="" episode=""
  local basename_file
  basename_file="$(basename "$mkv_file")"
  if [[ "$basename_file" =~ [Ss]([0-9]+)[Ee]([0-9]+) ]]; then
    season="${BASH_REMATCH[1]#0}"
    episode="${BASH_REMATCH[2]#0}"
  fi

  # ── OMDB ──
  echo "  Buscando contexto OMDB..."
  SERIES_CONTEXT=""
  fetch_omdb_context "$series_name" "$season" "$episode" || true

  # ── Buscar fonte de legenda ──
  local srt_orig=""
  local source_lang="${ARG_SOURCE_LANG}"
  local source_lang_name=""

  # Tentar SRT externo
  if [[ -n "$source_lang" ]]; then
    srt_orig=$(find_external_srt "$mkv_dir" "$basename" "$source_lang" 2>/dev/null) || true
  fi
  if [[ -z "$srt_orig" ]]; then
    for lang in "${LANG_PRIORITY[@]}"; do
      srt_orig=$(find_external_srt "$mkv_dir" "$basename" "$lang" 2>/dev/null) || true
      if [[ -n "$srt_orig" ]]; then
        source_lang="$lang"
        break
      fi
    done
  fi

  if [[ -n "$srt_orig" ]]; then
    source_lang_name=$(get_lang_name "$source_lang")
    echo "  SRT externo: ${source_lang_name} ($srt_orig)"
  else
    # Extrair do MKV
    echo "  Buscando legendas dentro do MKV..."

    local sub_index=""
    local all_subs_full
    all_subs_full=$(ffprobe -v error -select_streams s \
      -show_entries stream=index:stream_tags=language,title \
      -of csv=p=0 "$mkv_file" 2>/dev/null)

    local all_subs
    all_subs=$(ffprobe -v error -select_streams s \
      -show_entries stream=index:stream_tags=language \
      -of csv=p=0 "$mkv_file" 2>/dev/null)

    if [[ -n "$source_lang" && "$source_lang" != "spa-lat" ]]; then
      sub_index=$(echo "$all_subs" | grep ",${source_lang}" | head -1 | cut -d',' -f1 || true)
    fi

    if [[ -z "$sub_index" ]]; then
      for lang in "${LANG_PRIORITY[@]}"; do
        if [[ "$lang" == "spa-lat" ]]; then
          sub_index=$(echo "$all_subs_full" | grep -i ",spa," | grep -iE "latin|latino|latam|la\b|latinoam|MX|mexico|méxico|américa" | head -1 | cut -d',' -f1 || true)
          if [[ -n "$sub_index" ]]; then
            source_lang="spa"
            echo "  Encontrada legenda em espanhol latino!"
            break
          fi
        else
          sub_index=$(echo "$all_subs" | grep ",${lang}" | head -1 | cut -d',' -f1 || true)
          if [[ -n "$sub_index" ]]; then
            source_lang="$lang"
            break
          fi
        fi
      done
    fi

    if [[ -z "$sub_index" ]]; then
      echo "  ERRO: nenhuma legenda encontrada."
      return 2
    fi

    source_lang_name=$(get_lang_name "$source_lang")
    echo "  MKV stream $sub_index: ${source_lang_name}"

    srt_orig="/tmp/${basename}.orig.srt"
    ffmpeg -v error -y -i "$mkv_file" -map "0:${sub_index}" -c:s srt "$srt_orig"
  fi

  # Garantir nome do idioma
  if [[ -z "$source_lang_name" ]]; then
    source_lang_name=$(get_lang_name "${source_lang:-eng}")
  fi

  # ── Parsear SRT ──
  local block_nums=()
  local block_times=()
  local block_texts=()
  local current_num="" current_time="" current_text=""
  local state="num"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#$'\xef\xbb\xbf'}"
    line="${line%$'\r'}"

    if [[ "$state" == "num" ]]; then
      if [[ "$line" =~ ^[0-9]+$ ]]; then
        current_num="$line"
        state="time"
      fi
    elif [[ "$state" == "time" ]]; then
      current_time="$line"
      current_text=""
      state="text"
    elif [[ "$state" == "text" ]]; then
      if [[ -z "$line" ]]; then
        block_nums+=("$current_num")
        block_times+=("$current_time")
        block_texts+=("$current_text")
        state="num"
      else
        if [[ -n "$current_text" ]]; then
          current_text="${current_text}\n${line}"
        else
          current_text="$line"
        fi
      fi
    fi
  done < "$srt_orig"

  if [[ "$state" == "text" && -n "$current_text" ]]; then
    block_nums+=("$current_num")
    block_times+=("$current_time")
    block_texts+=("$current_text")
  fi

  local total_blocks=${#block_nums[@]}
  echo "  Blocos: $total_blocks | Idioma: ${source_lang_name}"

  # ── Montar prompt ──
  local context_block=""
  if [[ -n "$SERIES_CONTEXT" ]]; then
    context_block="
${SERIES_CONTEXT}
"
  fi

  local prompt_template
  prompt_template=$(cat <<PROMPT_END
Você é um localizador profissional de legendas para o mercado brasileiro.
${context_block}
TAREFA:
Localize (não apenas traduza) as legendas abaixo de ${source_lang_name} para português brasileiro (PT-BR).

REGRAS:
1. Faça uma LOCALIZAÇÃO, não tradução literal. Use linguagem natural e coloquial brasileira.
2. Palavrões e linguagem adulta devem ser traduzidos com intensidade equivalente ou maior.
   Público adulto 18+. NÃO suavize nada. Exemplos:
   - "mierda"/"shit" → "merda"
   - "joder"/"fuck" → "porra"/"caralho"/"foda-se"
   - "hijo de puta"/"son of a bitch" → "filho da puta"
   - "pendejo"/"asshole" → "cuzão"/"babaca"
   - "coño"/"damn" → "caralho"/"porra"
3. Gírias e expressões idiomáticas devem ser adaptadas para equivalentes brasileiros naturais.
4. Mantenha o formato exato: cada linha começa com o número seguido de ||| e depois o texto.
5. Tags entre colchetes devem ser traduzidas para português:
   [risas]/[laughter] → [risos], [música]/[music] → [música],
   [suspira]/[sighs] → [suspira], [gritos]/[screams] → [gritos], etc.
6. Mantenha \\n para representar quebras de linha dentro de um bloco.
7. NÃO adicione nem remova linhas. Retorne EXATAMENTE a mesma quantidade de linhas numeradas.
8. Retorne SOMENTE as linhas localizadas, sem explicações ou comentários.

Legendas:
PROMPT_END
)

  # ── Traduzir em batches ──
  local translated_texts=()
  local total_batches=$(( (total_blocks + BATCH_SIZE - 1) / BATCH_SIZE ))

  for (( batch_start=0; batch_start<total_blocks; batch_start+=BATCH_SIZE )); do
    local batch_end=$((batch_start + BATCH_SIZE))
    if (( batch_end > total_blocks )); then
      batch_end=$total_blocks
    fi

    local batch_num=$(( batch_start / BATCH_SIZE + 1 ))
    echo "  Batch $batch_num/$total_batches (blocos $((batch_start+1))-${batch_end})..."

    # Montar batch
    local batch_input=""
    for (( i=batch_start; i<batch_end; i++ )); do
      local idx=$((i - batch_start + 1))
      if [[ -n "$batch_input" ]]; then
        batch_input="${batch_input}\n${idx}|||${block_texts[$i]}"
      else
        batch_input="${idx}|||${block_texts[$i]}"
      fi
    done

    local full_prompt
    full_prompt=$(printf '%s\n%b' "$prompt_template" "$batch_input")

    # Chamar LLM com retries
    local max_retries=3
    local retry=0
    local batch_ok=false

    while (( retry < max_retries )); do
      local result
      result=$(call_llm "$full_prompt") || true

      if [[ "$result" == ERRO:* ]]; then
        echo "    Erro (tentativa $((retry+1))): ${result#ERRO:}" >&2
        retry=$((retry + 1))
        sleep 2
        continue
      fi

      if [[ -z "$result" ]]; then
        echo "    Resposta vazia (tentativa $((retry+1)))" >&2
        retry=$((retry + 1))
        sleep 2
        continue
      fi

      local count=$((batch_end - batch_start))
      for (( i=1; i<=count; i++ )); do
        local translated_line
        translated_line=$(echo "$result" | grep -E "^${i}\|\|\|" | sed "s/^${i}|||//" || true)
        if [[ -z "$translated_line" ]]; then
          local orig_idx=$((batch_start + i - 1))
          translated_line="${block_texts[$orig_idx]}"
          echo "    Aviso: bloco $i não encontrado, mantendo original" >&2
        fi
        translated_texts+=("$translated_line")
      done
      batch_ok=true
      break
    done

    if [[ "$batch_ok" != true ]]; then
      echo "    FALHA: mantendo originais para este batch" >&2
      for (( i=batch_start; i<batch_end; i++ )); do
        translated_texts+=("${block_texts[$i]}")
      done
    fi

    # Rate limiting
    if (( batch_end < total_blocks )); then
      sleep 1
    fi
  done

  # ── Gerar SRT ──
  {
    for (( i=0; i<total_blocks; i++ )); do
      echo "${block_nums[$i]}"
      echo "${block_times[$i]}"
      echo -e "${translated_texts[$i]}"
      echo ""
    done
  } > "$srt_ptbr"

  echo "  OK: $srt_ptbr ($total_blocks blocos)"
  return 0
}

# ════════════════════════════════════════════════════════════════
# ─── DESCOBRIR ARQUIVOS E PROCESSAR ────────────────────────────
# ════════════════════════════════════════════════════════════════

# Construir lista de MKVs
MKV_FILES=()

if [[ -f "$INPUT_PATH" ]]; then
  MKV_FILES+=("$INPUT_PATH")
elif [[ -d "$INPUT_PATH" ]]; then
  while IFS= read -r -d '' file; do
    MKV_FILES+=("$file")
  done < <(find "$INPUT_PATH" -type f -iname "*.mkv" -print0 | sort -z)
fi

if [[ ${#MKV_FILES[@]} -eq 0 ]]; then
  echo "Nenhum arquivo MKV encontrado em '$INPUT_PATH'."
  exit 1
fi

echo "Encontrados ${#MKV_FILES[@]} arquivo(s) MKV."
echo "════════════════════════════════════════════════════════════"
echo ""

for mkv_file in "${MKV_FILES[@]}"; do
  COUNT_TOTAL=$((COUNT_TOTAL + 1))
  echo "[$COUNT_TOTAL/${#MKV_FILES[@]}] $(basename "$mkv_file")"

  result=0
  process_file "$mkv_file" || result=$?

  case $result in
    0) COUNT_TRANSLATED=$((COUNT_TRANSLATED + 1)) ;;
    1) COUNT_SKIPPED=$((COUNT_SKIPPED + 1)) ;;
    *) COUNT_ERRORS=$((COUNT_ERRORS + 1)) ;;
  esac

  echo ""
done

# ─── Resumo final ───────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo "RESUMO"
echo "  Total:      $COUNT_TOTAL"
echo "  Traduzidos: $COUNT_TRANSLATED"
echo "  Pulados:    $COUNT_SKIPPED (PT-BR já existia)"
echo "  Erros:      $COUNT_ERRORS"
echo "════════════════════════════════════════════════════════════"
