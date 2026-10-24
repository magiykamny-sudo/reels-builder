#!/usr/bin/env bash
# Сборка вертикального рилса 1080x1920 из нескольких фото (или из одного).
# Использование: build_reel.sh "<фото 1> [<фото 2> ...]" "<хук>" [выходной_файл.mp4]
#   Фото: ссылки или пути, через пробел, запятую или перевод строки (берутся первые 4).
#
# Что получается (20 секунд):
#   0-20 с   фото сменяют друг друга плавными переходами, у каждого своё движение камеры
#            (наезд, отъезд, проезд вбок), логотип слева вверху, хук выезжает снизу
#   16-20 с  поверх всего финальная заставка с названием, ценой, сайтом и телефоном
# Музыка: если лежит файл assets/music.mp3, он подставляется под ролик.
# Размер файла держим не больше ~4,5 МБ: другие автоматизации скачивают ролик через Make (лимит 5 МБ).
set -euo pipefail

IMGS_RAW="${1:?нужна ссылка или путь хотя бы к одному фото}"
HOOK="${2:?нужен текст хука}"
# Английская строка под хуком (необязательно): передаётся переменной HOOK_EN.
HOOK_EN="${HOOK_EN:-}"
OUT="${3:-reel.mp4}"

# Эти строки можно менять без правки остального кода.
BRAND="МАГИЯ КАМНЯ"
TAGLINE="Памятники из гранита в Ярославле"
SINCE="С 1996 года"
PRICE="Цены от 25 000 ₽"
SITE="monuments76.ru"
PHONE="+7 (915) 988-01-40"

DUR=20          # длина ролика, секунд
SPLIT=16        # когда включается финальная заставка
FPS=30
MAXPHOTOS=4     # сколько фото использовать
XF=0.7          # длительность перехода между фото, секунд
LOGO_Y=220      # логотип ниже верхней полосы интерфейса Instagram и TikTok
FONT_BOLD="${FONT_BOLD:-/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO="$HERE/assets/logo.png"
MUSIC="$HERE/assets/music.mp3"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Фото: разобрать список, скачать ссылки. Недоступное фото пропускаем.
IMGS=()
for item in $(printf '%s' "$IMGS_RAW" | tr ',' ' '); do
  [[ ${#IMGS[@]} -ge $MAXPHOTOS ]] && break
  if [[ "$item" =~ ^https?:// ]]; then
    f="$WORK/photo${#IMGS[@]}"
    if curl -fsSL --retry 3 -o "$f" "$item"; then IMGS+=("$f"); else echo "Не скачалось фото: $item" >&2; fi
  elif [[ -f "$item" ]]; then
    IMGS+=("$item")
  else
    echo "Нет такого файла: $item" >&2
  fi
done
N=${#IMGS[@]}
[[ $N -ge 1 ]] || { echo "Ни одного фото не удалось получить" >&2; exit 1; }

# 2. Тексты: убрать длинное и среднее тире, перенести строки под ширину кадра.
export HOOK HOOK_EN BRAND TAGLINE SINCE PRICE SITE PHONE WORK
python3 - <<'PY'
import os, textwrap

def clean(s):
    return s.replace("—", ",").replace("–", ",").replace("−", ",").strip()

def put(name, text, width):
    lines = textwrap.wrap(clean(text), width=width) or [""]
    with open(os.path.join(os.environ["WORK"], name), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

put("hook.txt", os.environ["HOOK"], 17)

# Английская строка идёт отдельной плашкой под русским хуком.
# Положение считаем по числу строк русского хука (высота строки шрифта 76 пт около 89 px + 14 px интервал).
hook_lines = len(textwrap.wrap(clean(os.environ["HOOK"]), width=17)) or 1
en = clean(os.environ.get("HOOK_EN", ""))
if en:
    put("hook_en.txt", en, 26)
    block_h = hook_lines * 89 + (hook_lines - 1) * 14
    ru_box_bottom = 960 - 60 + block_h / 2 + 36
    with open(os.path.join(os.environ["WORK"], "layout.env"), "w") as f:
        f.write("EN_Y=%d\n" % int(ru_box_bottom + 18 + 22))
put("brand.txt", os.environ["BRAND"], 20)
put("tagline.txt", os.environ["TAGLINE"], 20)
put("since.txt", os.environ["SINCE"], 30)
put("price.txt", os.environ["PRICE"], 30)
put("site.txt", os.environ["SITE"], 30)
put("phone.txt", os.environ["PHONE"], 30)
PY

# 3. Звук: музыка, если есть, иначе тишина.
LOGO_IDX=$N
AUDIO_IDX=$((N + 1))
if [[ -f "$MUSIC" ]]; then
  AUDIO_IN=(-stream_loop -1 -i "$MUSIC")
else
  AUDIO_IN=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
fi
AUDIO_FILTER="[${AUDIO_IDX}:a]atrim=0:${DUR}[a]"

# 4. Длины клипов: N клипов с переходами XF встык дают ровно DUR секунд.
read -r CLIP_LEN FRAMES STEP < <(awk -v d="$DUR" -v n="$N" -v x="$XF" -v f="$FPS" 'BEGIN{
  l=(d+(n-1)*x)/n; printf "%.4f %d %.4f\n", l, int(l*f+0.5), l-x }')

# 5. Фильтры: у каждого фото своё движение камеры.
#    Фото сначала увеличивается до 2160x3840, чтобы при движении не было дрожания.
FILTER=""
for ((i=0; i<N; i++)); do
  case $((i % 4)) in
    0) ZX="z='1+0.45*on/${FRAMES}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'";;           # наезд
    1) ZX="z='1.45-0.45*on/${FRAMES}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'";;        # отъезд
    2) ZX="z='1.32':x='(iw-iw/zoom)*on/${FRAMES}':y='ih/2-(ih/zoom/2)'";;                 # проезд слева направо
    3) ZX="z='1.32':x='(iw-iw/zoom)*(1-on/${FRAMES})':y='ih/2-(ih/zoom/2)'";;             # проезд справа налево
  esac
  FILTER+="[${i}:v]scale=2160:3840:force_original_aspect_ratio=increase,crop=2160:3840,"
  FILTER+="zoompan=${ZX}:d=${FRAMES}:s=1080x1920:fps=${FPS},format=yuv420p,"
  FILTER+="eq=contrast=1.08:saturation=1.15,unsharp=5:5:0.6[c${i}];"
done

# Переходы между клипами (по кругу: сдвиг влево, наплыв, сдвиг вверх).
TRANS=(slideleft fade slideup)
if [[ $N -eq 1 ]]; then
  FILTER+="[c0]null[chain];"
else
  PREV="c0"
  for ((i=1; i<N; i++)); do
    OFF=$(awk -v s="$STEP" -v i="$i" 'BEGIN{printf "%.4f", s*i}')
    NEXT="x${i}"; [[ $i -eq $((N-1)) ]] && NEXT="chain"
    FILTER+="[${PREV}][c${i}]xfade=transition=${TRANS[$(((i-1) % 3))]}:duration=${XF}:offset=${OFF}[${NEXT}];"
    PREV="$NEXT"
  done
fi

T="fontfile=${FONT_BOLD}:fontcolor=white:text_align=center"
E="enable='between(t,${SPLIT},${DUR})'"
# Хук выезжает снизу за полсекунды и плавно проявляется.
HOOK_ANIM="y=(h-text_h)/2-60+160*pow(max(0\,1-(t-0.4)/0.6)\,2):alpha='min(1\,max(0\,(t-0.4)/0.4))'"

FILTER+="[chain]vignette=angle=PI/5,drawbox=x=0:y=0:w=iw:h=ih:color=black@0.22:t=fill[bg];"
FILTER+="[${LOGO_IDX}:v]scale=190:-1[logo];"
FILTER+="[bg][logo]overlay=x=50:y=${LOGO_Y}[v1];"
FILTER+="[v1]drawtext=${T}:textfile=${WORK}/hook.txt:fontsize=76:line_spacing=14:box=1:boxcolor=black@0.55:boxborderw=36:x=(w-text_w)/2:${HOOK_ANIM}:enable='between(t,0.4,${SPLIT})',"
if [[ -f "$WORK/hook_en.txt" ]]; then
  # shellcheck disable=SC1090
  source "$WORK/layout.env"
  EN_ANIM="y=${EN_Y}+160*pow(max(0\,1-(t-0.55)/0.6)\,2):alpha='min(1\,max(0\,(t-0.55)/0.4))'"
  FILTER+="drawtext=${T}:fontcolor=0xE6E6E6:textfile=${WORK}/hook_en.txt:fontsize=48:line_spacing=10:box=1:boxcolor=black@0.55:boxborderw=22:x=(w-text_w)/2:${EN_ANIM}:enable='between(t,0.55,${SPLIT})',"
fi
FILTER+="drawbox=x=0:y=0:w=iw:h=ih:color=0x8B1A1A@1.0:t=fill:${E},"
FILTER+="drawtext=${T}:textfile=${WORK}/brand.txt:fontsize=92:x=(w-text_w)/2:y=520:${E},"
FILTER+="drawtext=${T}:textfile=${WORK}/tagline.txt:fontsize=56:line_spacing=12:x=(w-text_w)/2:y=700:${E},"
FILTER+="drawtext=${T}:textfile=${WORK}/since.txt:fontsize=56:x=(w-text_w)/2:y=900:${E},"
FILTER+="drawtext=${T}:textfile=${WORK}/price.txt:fontsize=56:x=(w-text_w)/2:y=990:${E},"
FILTER+="drawtext=${T}:textfile=${WORK}/site.txt:fontsize=68:x=(w-text_w)/2:y=1180:${E},"
FILTER+="drawtext=${T}:textfile=${WORK}/phone.txt:fontsize=68:x=(w-text_w)/2:y=1290:${E}[v];"
FILTER+="${AUDIO_FILTER}"

# 6. Кодирование. Потолок битрейта подобран так, чтобы файл не превышал ~4,5 МБ.
INPUTS=()
for f in "${IMGS[@]}"; do INPUTS+=(-loop 1 -framerate "$FPS" -t "$(awk -v l="$CLIP_LEN" 'BEGIN{printf "%.3f", l+0.1}')" -i "$f"); done

ffmpeg -y -hide_banner -loglevel error \
  "${INPUTS[@]}" -i "$LOGO" "${AUDIO_IN[@]}" \
  -filter_complex "$FILTER" \
  -map "[v]" -map "[a]" -t "$DUR" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 24 -maxrate 1600k -bufsize 3200k -preset medium \
  -c:a aac -b:a 112k -ar 48000 -ac 2 -g 60 -keyint_min 60 -movflags +faststart \
  "$OUT"

SIZE=$(stat -c %s "$OUT")
echo "Готово: $OUT, фото: $N, размер: $((SIZE / 1024)) КБ"
if [[ $SIZE -gt 4700000 ]]; then
  # Файл слишком большой для Make (лимит 5 МБ): пересжимаем с меньшим битрейтом.
  echo "Файл больше 4,7 МБ, пересжимаю" >&2
  ffmpeg -y -hide_banner -loglevel error -i "$OUT" -c:v libx264 -profile:v high -pix_fmt yuv420p \
    -b:v 1100k -maxrate 1250k -bufsize 2500k -preset medium -c:a copy -g 60 -keyint_min 60 \
    -movflags +faststart "$WORK/small.mp4"
  mv "$WORK/small.mp4" "$OUT"
  SIZE=$(stat -c %s "$OUT")
  echo "После пересжатия: $((SIZE / 1024)) КБ"
fi
