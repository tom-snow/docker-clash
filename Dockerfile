# [Document docker poetry best practices #1879](https://github.com/python-poetry/poetry/discussions/1879#discussioncomment-216865)

# `python-base` sets up all our shared environment variables
FROM python:3.8-alpine as python-base

# python
ENV PYTHONUNBUFFERED=1 \
    # prevents python creating .pyc files
    PYTHONDONTWRITEBYTECODE=1 \
    \
    # pip
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PIP_DEFAULT_TIMEOUT=100 \
    \
    # poetry
    # https://python-poetry.org/docs/configuration/#using-environment-variables
    POETRY_VERSION=1.1.12 \
    # make poetry install to this location
    POETRY_HOME="/opt/poetry" \
    # make poetry create the virtual environment in the project's root
    # it gets named `.venv`
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    # do not ask any interactive question
    POETRY_NO_INTERACTION=1 \
    \
    # paths
    # this is where our requirements + virtual environment will live
    PYSETUP_PATH="/opt/pysetup" \
    VENV_PATH="/opt/pysetup/.venv" \
    \
    GOSU_VERSION=1.14 \
    UI_DIR=/ui \
    PKG_NAME="clashutil" \
    CLASH_PATH="/usr/local/bin/clash"


ENV PATH="$POETRY_HOME/bin:$VENV_PATH/bin:$PATH"

# [Alpine Linux 源使用帮助](https://mirrors.ustc.edu.cn/help/alpine.html)
RUN set -eux; \
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories; \
    # pip
    pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple; \
    \
    # clashutil lib
    apk add --no-cache iptables libcap; \
    \
    # gosu
    apk add --no-cache su-exec; \
    apk add --no-cache --virtual .gosu-deps \
    ca-certificates \
    dpkg \
    gnupg \
    ; \
    \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
    \
    # verify the signature
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
    command -v gpgconf && gpgconf --kill all || :; \
    rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
    \
    # clean up fetch dependencies
    apk del --no-network .gosu-deps; \
    \
    chmod +x /usr/local/bin/gosu; \
    # verify that the binary works
    gosu --version; \
    gosu nobody true

# `builder-base` stage is used to build deps + create our virtual environment
FROM python-base as builder-base
RUN apk add --no-cache \
    # deps for installing poetry
    curl \
    # deps for building python deps
    # build-essential
    # [What is the alpine equivalent to build-essential? #24](https://github.com/gliderlabs/docker-alpine/issues/24#issuecomment-411117124)
    build-base \
    gcc \
    libressl-dev \
    musl-dev \
    libffi-dev

# install poetry - respects $POETRY_VERSION & $POETRY_HOME
RUN curl -sSL https://install.python-poetry.org | python3 -

# copy project requirement files here to ensure they will be cached.
WORKDIR $PYSETUP_PATH
# lock文件可能需要主动lock依赖如`poetry lock`
COPY poetry.lock pyproject.toml ./
# install runtime deps - uses $POETRY_VIRTUALENVS_IN_PROJECT internally
RUN poetry install --no-dev

FROM builder-base as builder-dev
WORKDIR $PYSETUP_PATH
COPY "./$PKG_NAME" "./$PKG_NAME"
RUN poetry install --no-dev

FROM python-base as clash-bin
# download clash binary
RUN set -eux;\
    apk add --no-cache curl;\
    \
    # find archtecture
    arch=''; \
    case "$(uname -m)" in \
        "x86_64")     arch='amd64';;\
        "aarch64")    arch='armv8';;\
        *)            echo "Unable to determine system arch"; return 1;;\
    esac;\
    \
    # get url of clash premium
    url=$(curl -Ls -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/Dreamacro/clash/releases/tags/premium \
    | grep browser_download_url \
    | cut -d '"' -f 4 \
    | grep "linux-$arch.*.gz"); \
    \
    if [ -z "$url" ];then\
        echo "not found clash premium for url: $url"; \
        return 1;\
    fi;\
    \
    echo "downloading clash from $url"; \
    # download clash
    curl -sSL "$url" | gzip -d > "$CLASH_PATH";\
    chmod +x "$CLASH_PATH"

# `production` image used for runtime
FROM python-base as production
COPY --from=builder-dev $PYSETUP_PATH $PYSETUP_PATH
COPY --from=clash-bin $CLASH_PATH $CLASH_PATH
# yacd fontend for clash
COPY --from=haishanh/yacd:v0.3.4 /usr/share/nginx/html/ $UI_DIR

# clash bin
RUN set -eux; setcap 'cap_net_admin,cap_net_bind_service=+ep' "$CLASH_PATH"

COPY ./entrypoint.sh /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
