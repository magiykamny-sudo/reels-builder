#!/usr/bin/env bash
# Сборка вертикального рилса 1080x1920 из одного фото.
# Использование: build_reel.sh <фото: путь или ссылка> "<хук>" [выходной_файл.mp4]
#
# Что получается (20 секунд):
#   0-16 с   фото с плавным наездом, логотип сверху, хук крупным текстом
#   16-20 с  финальная заставка с названием, ценой, сайтом и телефоном
# Музыка: если лежит файл assets/music.mp3, он подставляется под ролик.
# Без него в ролике тихая звуковая дорожка (так видео принимают все площадки).
set -euo pipefail

IMG="${1:?нужна ссылка или путь к фото}"
HOOK="${2:?нужен текст хука}"
OUT="${3:-reel.mp4}"

# Эти строки можно менять без правки остального кода.
BRAND="МАГИЯ КАМНЯ"
TAGLINE="Памятники из гранита в Ярославле"
SINCE="С 1996 года"
PRICE="Цены от 25 000 ₽"
SITE="monuments76.ru"
PHONE="+7 (915) 988-01-40"

DUR=20
SPLIT=16
FPS=30
FONT_BOLD="${FONT_BOLD:-/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf}"
FONT_REG="${FONT_REG:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO="$HERE/assets/logo.png"
MUSIC="$HERE/assets/music.mp3"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Фото: скачать, если это ссылка.
if [[ "$IMG" =~ ^https?:// ]]; then
  curl -fsSL --retry 3 -o "$WORK/photo" "$IMG"
  IMG="$WORK/photo"
fi

# 2. Тексты: убрать длинное и среднее тире, перенести строки под ширину кадра.
export HOOK BRAND TAGLINE SINCE PRICE SITE PHONE WORK
python3 - <<'PY'
import os, textwrap

def clean(s):
    return s.replace("—", ",").replace("–", ",").replace("−", ",").strip()

def put(name, text, width):
    lines = textwrap.wrap(clean(text), width=width) or [""]
    with open(os.path.join(os.environ["WORK"], name), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

put("hook.txt", os.environ["HOOK"], 17)
put("brand.txt", os.environ["BRAND"], 20)
put("tagline.txt", os.environ["TAGLINE"], 20)
put("since.txt", os.environ["SINCE"], 30)
put("price.txt", os.environ["PRICE"], 30)
put("site.txt", os.environ["SITE"], 30)
put("phone.txt", os.environ["PHONE"], 30)
PY

# 3. Звук: музыка, если есть, иначе тишина.
if [[ -f "$MUSIC" ]]; then
  AUDIO_IN=(-stream_loop -1 -i "$MUSIC")
  AUDIO_FILTER="[2:a]atrim=0:${DUR},afade=t=in:d=1,afade=t=out:st=$((DUR-2)):d=2,volume=0.8[a]"
else
  AUDIO_IN=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
  AUDIO_FILTER="[2:a]atrim=0:${DUR}[a]"
fi

FRAMES=$((DUR * FPS))
T="fontfile=${FONT_BOLD}:fontcolor=white"
E="enable='between(t,${SPLIT},${DUR})'"

# 4. Сборка.
ffmpeg -y -hide_banner -loglevel error \
  -i "$IMG" -i "$LOGO" "${AUDIO_IN[@]}" \
  -filter_complex "
    [0:v]scale=1620:2880:force_original_aspect_ratio=increase,crop=1620:2880,
         zoompan=z='min(1+0.0003*on,1.18)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${FRAMES}:s=1080x1920:fps=${FPS},
         format=yuv420p,
         drawbox=x=0:y=0:w=iw:h=ih:color=black@0.28:t=fill[bg];
    [1:v]scale=240:-1[logo];
    [bg][logo]overlay=x=(W-w)/2:y=150[v1];
    [v1]drawtext=${T}:textfile=${WORK}/hook.txt:fontsize=76:line_spacing=14:box=1:boxcolor=black@0.55:boxborderw=36:x=(w-text_w)/2:y=(h-text_h)/2-60:enable='between(t,0.4,${SPLIT})',
        drawbox=x=0:y=0:w=iw:h=ih:color=0x8B1A1A@1.0:t=fill:${E},
        drawtext=${T}:textfile=${WORK}/brand.txt:fontsize=92:x=(w-text_w)/2:y=520:${E},
        drawtext=${T}:textfile=${WORK}/tagline.txt:fontsize=56:line_spacing=12:x=(w-text_w)/2:y=700:${E},
        drawtext=${T}:textfile=${WORK}/since.txt:fontsize=56:x=(w-text_w)/2:y=900:${E},
        drawtext=${T}:textfile=${WORK}/price.txt:fontsize=56:x=(w-text_w)/2:y=990:${E},
        drawtext=${T}:textfile=${WORK}/site.txt:fontsize=68:x=(w-text_w)/2:y=1180:${E},
        drawtext=${T}:textfile=${WORK}/phone.txt:fontsize=68:x=(w-text_w)/2:y=1290:${E}[v];
    ${AUDIO_FILTER}
  " \
  -map "[v]" -map "[a]" -t "$DUR" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 28 -maxrate 2200k -bufsize 4400k -preset medium \
  -c:a aac -b:a 128k -ar 48000 -ac 2 -g 60 -keyint_min 60 -movflags +faststart \
  "$OUT"

echo "Готово: $OUT"
