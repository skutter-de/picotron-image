FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY daemon /daemon
COPY setup-daemon /setup-daemon
COPY setup-cart /setup-cart
COPY host-terminal.p64 /host-terminal.p64
COPY pty_bridge.py /pty_bridge.py

FROM ghcr.io/ublue-os/base-main:gts

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

RUN bootc container lint
