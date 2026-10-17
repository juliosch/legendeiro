---
name: legendar
description: Gera legendas .pt-BR.srt para arquivos MKV, com o próprio Claude localizando o texto (sem API key). Use quando o usuário pedir para legendar, traduzir ou localizar legendas de um vídeo/série para português brasileiro.
argument-hint: <arquivo.mkv | diretório>
allowed-tools: Bash(./legendeiro.sh:*), Bash(LEGENDEIRO_WORK=.legendeiro-work ./legendeiro.sh:*), Bash(find:*), Read, Write
---

# Legendar MKV para PT-BR

Alvo: `$ARGUMENTS` (arquivo `.mkv` ou diretório; se vazio, pergunte ao usuário).

O `legendeiro.sh` (na raiz deste repo) faz a parte mecânica: escolhe a melhor legenda de origem, extrai, divide em lotes e remonta o SRT com os tempos originais. **A localização é feita pelo Claude.** As regras estão em `.claude/skills/legendar/regras.md`. Leia esse arquivo antes de traduzir qualquer coisa.

Os lotes (`lote_NNN.txt`, até 150 blocos cada) servem só para que cada arquivo gravado tenha um tamanho razoável. **Um episódio é traduzido inteiro por um único agente**, que lê todos os lotes e mantém a consistência. Não divida um episódio entre agentes.

## 1. Listar e preparar

- Arquivo: processe só ele.
- Diretório: `find "<dir>" -type f -iname '*.mkv' | sort`.

Para cada arquivo:

```bash
LEGENDEIRO_WORK=.legendeiro-work ./legendeiro.sh prepare "<arquivo.mkv>"
```

- Saída `1`: já existe PT-BR. Pule e conte como pulado.
- Saída `2`: erro (sem legenda, por exemplo). Registre e siga para o próximo.
- Saída `0`: anote o caminho absoluto da linha `WORKDIR: ...` e o idioma de origem.

## 2. Contexto da série

O contexto fica em `.legendeiro-work/contexto-<serie>.md`, com o nome da série em kebab-case (ex.: `contexto-crystal-lake.md`). Ele persiste entre execuções: se já existir, leia e reaproveite.

Se não existir (ou se este episódio trouxer personagens e termos novos), leia os lotes do primeiro episódio e escreva ou atualize o arquivo, curto e objetivo:

- Série/filme provável, época, gênero, tom (comédia escrachada, drama, terror...).
- Personagens: nome, **gênero**, papel, como fala (formal, gíria, sotaque).
- Relações e tratamento: quem trata quem por "você", "a senhora", apelidos.
- Glossário: termos recorrentes, bordões, piadas internas, rótulos de fala (Mujer → Mulher) e como ficam em PT-BR.

Se o diretório misturar séries diferentes, escreva um contexto por série.

## 3. Localizar

Para cada `lote_NNN.txt` do workdir, gere `lote_NNN.ptbr.txt` no mesmo workdir (uma linha `N|||texto` por linha de entrada, mesmos números), seguindo `regras.md` e o contexto da série.

- **Um episódio:** traduza você mesmo. Leia todos os lotes e grave um `.ptbr.txt` por lote com Write. Depois rode o passo 4.
- **Vários episódios:** dispare um subagente `general-purpose` **por episódio**, todos na mesma mensagem (no máximo 5 por vez; se houver mais, mande a próxima leva quando a anterior terminar). Prompt de cada um (preencha os caminhos absolutos):

  > Você é um localizador de legendas para PT-BR. Leia `<repo>/.claude/skills/legendar/regras.md` e `<contexto da série>` e siga-os à risca. Em `<WORKDIR>` há os arquivos `lote_*.txt` de um episódio (origem: <idioma>). Leia **todos** antes de começar, para entender o episódio inteiro. Para cada `lote_NNN.txt`, grave com Write `lote_NNN.ptbr.txt`: uma linha `N|||texto` para cada linha de entrada, mesmos números, nada além disso. Depois rode `<repo>/legendeiro.sh finish "<WORKDIR>"`. Se ele listar blocos sem tradução, corrija só essas linhas e rode de novo. Responda com a linha `OK: ...` do finish, ou com o problema encontrado.

## 4. Montar o SRT

(No caso de um episódio; com subagentes, cada um já roda o finish.)

```bash
./legendeiro.sh finish "<WORKDIR>"
```

- `OK: ...`: pronto. O `.pt-BR.srt` foi gravado ao lado do MKV e o workdir foi apagado.
- `ERRO: N bloco(s) sem tradução`: a saída lista o lote e os números que faltam. Corrija só essas linhas no `lote_NNN.ptbr.txt` correspondente e rode `finish` de novo. Nunca preencha com o texto original para passar na validação.

## 5. Resumo

No fim, informe: arquivos gerados, pulados (PT-BR já existia) e erros, com o motivo.
