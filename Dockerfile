ARG BUILD_FROM
FROM $BUILD_FROM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apk add --no-cache ffmpeg bash alsa-utils usbutils pulseaudio-utils coreutils wget ca-certificates

# MediaMTX only required if you enable RTSP output. Safe to include.
# We pull the correct arch in a tiny way by using uname -m at build time.
RUN set -e;     ARCH="$(uname -m)";     case "$ARCH" in       x86_64) MTX_ARCH="amd64" ;;       aarch64) MTX_ARCH="arm64" ;;       armv7l|armv7) MTX_ARCH="armv7" ;;       armv6l|armhf) MTX_ARCH="armv6" ;;       *) MTX_ARCH="amd64" ;;     esac;     wget -qO- "https://github.com/bluenviron/mediamtx/releases/download/v1.5.1/mediamtx_v1.5.1_linux_${MTX_ARCH}.tar.gz" | tar xz -C /usr/local/bin/ &&     chmod +x /usr/local/bin/mediamtx

COPY run.sh /run.sh
COPY mediamtx.yml /mediamtx.yml
RUN chmod +x /run.sh

CMD ["/run.sh"]
