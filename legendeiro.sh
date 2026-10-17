#!/usr/bin/env bash
set -euo pipefail

# ─── Configuração ───────────────────────────────────────────────
BATCH_SIZE=40        # blocos SRT por request (modo API)
LOTE_SIZE=150        # blocos SRT por lote (modo prepare/finish)
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
Uso: $0 <caminho> <LLM_API_KEY> [opções]
     $0 prepare <arquivo.mkv> [--source-lang X]
     $0 finish <workdir>

Modo API (padrão): traduz via LLM e gera o .pt-BR.srt.
  caminho        - Arquivo MKV ou diretório (busca recursiva por .mkv)
  LLM_API_KEY    - Chave de API do LLM (use "none" para ollama)

Modo lotes (sem LLM, usado pela skill /legendar do Claude Code):
  prepare        - Extrai a melhor legenda e divide em lotes "N|||texto"
                   num diretório de trabalho (impresso como WORKDIR: ...)
  finish         - Lê os lote_*.ptbr.txt do workdir e gera o .pt-BR.srt

Opções:
  --provider P     - Provider do LLM (padrão: gemini)
                     Opções: gemini, openai, anthropic, groq, ollama
  --model M        - Modelo específico (se omitido, usa o padrão do provider)
  --source-lang X  - Idioma de origem: spa, eng, etc (padrão: auto-detecta)

Providers e modelos padrão:
  gemini     →  $(default_model_for gemini)
  openai     →  $(default_model_for openai)
  anthropic  →  $(default_model_for anthropic)
  groq       →  $(default_model_for groq)
  ollama     →  $(default_model_for ollama)

Exemplos:
  $0 ./videos/ GEMINI_KEY
  $0 video.mkv GEMINI_KEY
  $0 ./series/ OPENAI_KEY --provider openai
  $0 . none --provider ollama --model llama3.1
  $0 prepare video.mkv
EOF
  exit 2
}

ARG_SOURCE_LANG=""

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

# ─── Buscar stream de legenda por idioma no MKV ────────────────
find_stream_by_lang() {
  awk -F, -v lang="$2" '$2 == lang { print $1; exit }' <<< "$1"
}

# ─── Prioridade de idiomas ──────────────────────────────────────
LANG_PRIORITY=(spa-lat spa por fre ita ron cat ger dut rus pol cze gre ara eng)

# ─── Checar se já existe PT-BR ──────────────────────────────────
# Retorna 0 (e imprime o caminho) se já existir legenda PT-BR
find_existing_ptbr() {
  local mkv_file="$1"
  local base="${mkv_file%.*}"
  local ptbr_patterns="pt-BR pt-br pt_BR pt_br ptbr por.br brazilian"
  for suffix in $ptbr_patterns; do
    for candidate in "${base}.${suffix}.srt" "${base}.${suffix}.SRT"; do
      if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
  done
  return 1
}

# ─── Buscar melhor legenda de origem ────────────────────────────
# Copia/extrai a legenda escolhida para $2 e define SOURCE_LANG_NAME.
# Retorna 2 se nenhuma legenda for encontrada.
find_source_srt() {
  local mkv_file="$1"
  local dest="$2"
  local basename
  basename="$(basename "${mkv_file%.*}")"
  local mkv_dir
  mkv_dir="$(dirname "$mkv_file")"

  local srt_orig=""
  local source_lang="${ARG_SOURCE_LANG}"

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
    SOURCE_LANG_NAME=$(get_lang_name "$source_lang")
    echo "  SRT externo: ${SOURCE_LANG_NAME} ($srt_orig)"
    cp "$srt_orig" "$dest"
    return 0
  fi

  # Extrair do MKV
  echo "  Buscando legendas dentro do MKV..."

  local sub_index=""
  # Uma linha por stream: index,language[,title]
  local all_subs
  all_subs=$(ffprobe -v error -select_streams s \
    -show_entries stream=index:stream_tags=language,title \
    -of csv=p=0 "$mkv_file" 2>/dev/null)

  if [[ -n "$source_lang" && "$source_lang" != "spa-lat" ]]; then
    sub_index=$(find_stream_by_lang "$all_subs" "$source_lang")
  fi

  if [[ -z "$sub_index" ]]; then
    for lang in "${LANG_PRIORITY[@]}"; do
      if [[ "$lang" == "spa-lat" ]]; then
        sub_index=$(echo "$all_subs" | grep -i ",spa," | grep -iE "latin|latino|latam|la\b|latinoam|MX|mexico|méxico|américa" | head -1 | cut -d',' -f1 || true)
        if [[ -n "$sub_index" ]]; then
          source_lang="spa"
          echo "  Encontrada legenda em espanhol latino!"
          break
        fi
      else
        sub_index=$(find_stream_by_lang "$all_subs" "$lang")
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

  SOURCE_LANG_NAME=$(get_lang_name "$source_lang")
  echo "  MKV stream $sub_index: ${SOURCE_LANG_NAME}"

  ffmpeg -v error -y -i "$mkv_file" -map "0:${sub_index}" -c:s srt "$dest"
}

# ─── Parsear SRT ────────────────────────────────────────────────
# Preenche BLOCK_NUMS, BLOCK_TIMES e BLOCK_TEXTS (quebras de linha
# dentro de um bloco viram o literal \n)
parse_srt() {
  BLOCK_NUMS=()
  BLOCK_TIMES=()
  BLOCK_TEXTS=()
  local current_num="" current_time="" current_text=""
  local state="num"
  local line

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
        BLOCK_NUMS+=("$current_num")
        BLOCK_TIMES+=("$current_time")
        BLOCK_TEXTS+=("$current_text")
        state="num"
      else
        if [[ -n "$current_text" ]]; then
          current_text="${current_text}\n${line}"
        else
          current_text="$line"
        fi
      fi
    fi
  done < "$1"

  if [[ "$state" == "text" && -n "$current_text" ]]; then
    BLOCK_NUMS+=("$current_num")
    BLOCK_TIMES+=("$current_time")
    BLOCK_TEXTS+=("$current_text")
  fi
}

# ─── Gerar SRT ──────────────────────────────────────────────────
# Usa BLOCK_NUMS/BLOCK_TIMES com os textos de TRANSLATED_TEXTS
write_srt() {
  local total_blocks=${#BLOCK_NUMS[@]}
  {
    for (( i=0; i<total_blocks; i++ )); do
      echo "${BLOCK_NUMS[$i]}"
      echo "${BLOCK_TIMES[$i]}"
      echo -e "${TRANSLATED_TEXTS[$i]}"
      echo ""
    done
  } > "$1"
}

# ════════════════════════════════════════════════════════════════
# ─── MODO API: PROCESSAR UM ARQUIVO MKV ────────────────────────
# ════════════════════════════════════════════════════════════════
process_file() {
  local mkv_file="$1"
  local basename
  basename="$(basename "${mkv_file%.*}")"
  local srt_ptbr="${mkv_file%.*}.pt-BR.srt"

  local existing
  if existing=$(find_existing_ptbr "$mkv_file"); then
    echo "  SKIP: PT-BR já existe ($existing)"
    return 1
  fi

  local srt_orig="${TMP_DIR}/${basename}.orig.srt"
  find_source_srt "$mkv_file" "$srt_orig" || return 2
  local source_lang_name="$SOURCE_LANG_NAME"

  parse_srt "$srt_orig"
  local total_blocks=${#BLOCK_NUMS[@]}
  echo "  Blocos: $total_blocks | Idioma: ${source_lang_name}"

  # ── Montar prompt ──

  local prompt_template
  prompt_template=$(cat <<PROMPT_END
Você é um localizador profissional de legendas para o mercado brasileiro.

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
  TRANSLATED_TEXTS=()
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
      # Escapar \n do texto para \\n antes de montar o batch, para que o printf
      # não expanda quebras internas do bloco como separadores de linhas do prompt
      local escaped_text="${BLOCK_TEXTS[$i]//\\n/\\\\n}"
      if [[ -n "$batch_input" ]]; then
        batch_input="${batch_input}\n${idx}|||${escaped_text}"
      else
        batch_input="${idx}|||${escaped_text}"
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
        translated_line=$(echo "$result" | awk -v n="${i}" '$0 ~ "^"n"[|][|][|]" && substr($0,1,length(n))+0==n+0 && substr($0,length(n)+1,1)=="|" {print substr($0,length(n)+4); exit}' || true)
        if [[ -z "$translated_line" ]]; then
          local orig_idx=$((batch_start + i - 1))
          translated_line="${BLOCK_TEXTS[$orig_idx]}"
          echo "    Aviso: bloco $i não encontrado, mantendo original" >&2
        fi
        TRANSLATED_TEXTS+=("$translated_line")
      done
      batch_ok=true
      break
    done

    if [[ "$batch_ok" != true ]]; then
      echo "    FALHA: mantendo originais para este batch" >&2
      for (( i=batch_start; i<batch_end; i++ )); do
        TRANSLATED_TEXTS+=("${BLOCK_TEXTS[$i]}")
      done
    fi

    # Rate limiting
    if (( batch_end < total_blocks )); then
      sleep 1
    fi
  done

  write_srt "$srt_ptbr"
  echo "  OK: $srt_ptbr ($total_blocks blocos)"
  return 0
}

main_api() {
  [[ $# -lt 2 ]] && usage

  INPUT_PATH="$1"
  LLM_KEY="$2"
  shift 2

  PROVIDER="gemini"
  MODEL=""

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

  # Diretório temporário (legendas extraídas do MKV)
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Construir lista de MKVs
  local mkv_files=()

  if [[ -f "$INPUT_PATH" ]]; then
    mkv_files+=("$INPUT_PATH")
  elif [[ -d "$INPUT_PATH" ]]; then
    while IFS= read -r -d '' file; do
      mkv_files+=("$file")
    done < <(find "$INPUT_PATH" -type f -iname "*.mkv" -print0 | sort -z)
  fi

  if [[ ${#mkv_files[@]} -eq 0 ]]; then
    echo "Nenhum arquivo MKV encontrado em '$INPUT_PATH'."
    exit 1
  fi

  echo "Encontrados ${#mkv_files[@]} arquivo(s) MKV."
  echo "════════════════════════════════════════════════════════════"
  echo ""

  local count_total=0 count_translated=0 count_skipped=0 count_errors=0

  for mkv_file in "${mkv_files[@]}"; do
    count_total=$((count_total + 1))
    echo "[$count_total/${#mkv_files[@]}] $(basename "$mkv_file")"

    local result=0
    process_file "$mkv_file" || result=$?

    case $result in
      0) count_translated=$((count_translated + 1)) ;;
      1) count_skipped=$((count_skipped + 1)) ;;
      *) count_errors=$((count_errors + 1)) ;;
    esac

    echo ""
  done

  # Resumo final
  echo "════════════════════════════════════════════════════════════"
  echo "RESUMO"
  echo "  Total:      $count_total"
  echo "  Traduzidos: $count_translated"
  echo "  Pulados:    $count_skipped (PT-BR já existia)"
  echo "  Erros:      $count_errors"
  echo "════════════════════════════════════════════════════════════"
}

# ════════════════════════════════════════════════════════════════
# ─── MODO LOTES: PREPARE / FINISH ──────────────────────────────
# ════════════════════════════════════════════════════════════════
# Códigos de saída: 0 = ok, 1 = pulado (PT-BR já existe), 2 = erro

cmd_prepare() {
  [[ $# -lt 1 ]] && usage
  local mkv_file="$1"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
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

  if [[ ! -f "$mkv_file" ]]; then
    echo "Erro: '$mkv_file' não encontrado."
    exit 2
  fi

  local existing
  if existing=$(find_existing_ptbr "$mkv_file"); then
    echo "SKIP: PT-BR já existe ($existing)"
    exit 1
  fi

  # LEGENDEIRO_WORK define onde ficam os workdirs (padrão: $TMPDIR)
  local work_base="${LEGENDEIRO_WORK:-${TMPDIR:-/tmp}}"
  mkdir -p "$work_base"
  work_base=$(cd "$work_base" && pwd)
  local workdir
  workdir=$(mktemp -d "${work_base%/}/legendeiro.XXXXXX")

  if ! find_source_srt "$mkv_file" "$workdir/source.srt"; then
    rm -rf "$workdir"
    exit 2
  fi

  parse_srt "$workdir/source.srt"
  local total_blocks=${#BLOCK_NUMS[@]}
  if (( total_blocks == 0 )); then
    echo "  ERRO: legenda de origem vazia."
    rm -rf "$workdir"
    exit 2
  fi

  # Lotes com numeração global (1..total), mesmo formato do modo API
  local lotes=0
  for (( start=0; start<total_blocks; start+=LOTE_SIZE )); do
    lotes=$((lotes + 1))
    local lote_file
    lote_file=$(printf '%s/lote_%03d.txt' "$workdir" "$lotes")
    for (( i=start; i<start+LOTE_SIZE && i<total_blocks; i++ )); do
      printf '%s|||%s\n' "$((i + 1))" "${BLOCK_TEXTS[$i]}"
    done > "$lote_file"
  done

  printf 'MKV_FILE=%q\nSRT_PTBR=%q\nSOURCE_LANG_NAME=%q\nLOTE_SIZE=%q\n' \
    "$mkv_file" "${mkv_file%.*}.pt-BR.srt" "$SOURCE_LANG_NAME" "$LOTE_SIZE" > "$workdir/meta"

  echo "  Blocos: $total_blocks | Idioma: ${SOURCE_LANG_NAME} | Lotes: $lotes"
  echo "WORKDIR: $workdir"
}

cmd_finish() {
  [[ $# -ne 1 ]] && usage
  local workdir="$1"

  if [[ ! -f "$workdir/meta" || ! -f "$workdir/source.srt" ]]; then
    echo "Erro: '$workdir' não é um diretório de trabalho do prepare."
    exit 2
  fi
  # shellcheck source=/dev/null
  source "$workdir/meta"

  parse_srt "$workdir/source.srt"
  local total_blocks=${#BLOCK_NUMS[@]}

  TRANSLATED_TEXTS=()
  local re='^([0-9]+)[|][|][|](.*)$'
  local f line n
  for f in "$workdir"/lote_*.ptbr.txt; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ "$line" =~ $re ]]; then
        n=$((10#${BASH_REMATCH[1]}))
        if (( n >= 1 && n <= total_blocks )) && [[ -n "${BASH_REMATCH[2]}" ]]; then
          TRANSLATED_TEXTS[$((n - 1))]="${BASH_REMATCH[2]}"
        fi
      fi
    done < "$f"
  done

  # Validar: todo bloco precisa de tradução
  local missing="" missing_count=0 last_lote=0
  for (( i=0; i<total_blocks; i++ )); do
    if [[ -z "${TRANSLATED_TEXTS[$i]:-}" ]]; then
      missing_count=$((missing_count + 1))
      local lote=$(( i / LOTE_SIZE + 1 ))
      if (( lote != last_lote )); then
        missing="${missing}$(printf '\n  lote_%03d.txt:' "$lote")"
        last_lote=$lote
      fi
      missing="${missing} $((i + 1))"
    fi
  done

  if (( missing_count > 0 )); then
    echo "ERRO: $missing_count bloco(s) sem tradução:${missing}"
    exit 2
  fi

  write_srt "$SRT_PTBR"
  rm -rf "$workdir"
  echo "OK: $SRT_PTBR ($total_blocks blocos)"
}

# ─── Entrada ────────────────────────────────────────────────────
case "${1:-}" in
  prepare) shift; cmd_prepare "$@" ;;
  finish)  shift; cmd_finish "$@" ;;
  *)       main_api "$@" ;;
esac
