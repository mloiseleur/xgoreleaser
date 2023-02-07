ARG GO_VERSION=1.19

# OS-X SDK parameters
# NOTE: when changing version here, make sure to also change OSX_CODENAME below to match
ARG OSX_SDK=MacOSX11.3.sdk

# To get the SHA sum do:
# wget https://s3.dockerproject.org/darwin/v2/${OSX_SDK}.tar.xz
#
# We no longer use this.
#
# ARG OSX_SDK_SUM=694a66095a3514328e970b14978dc78c0f4d170e590fa7b2c3d3674b75f0b713

# OSX-cross parameters. Go 1.15 requires OSX >= 10.11
ARG OSX_VERSION_MIN=11.3
# Choose latest commit from here: https://github.com/tpoechtrager/osxcross/commits/master/CHANGELOG
ARG OSX_CROSS_COMMIT=3351f5573c5c3f38a28a82df1ae09cad6d70f83d

# Libtool parameters
ARG LIBTOOL_VERSION=2.4.6_4
# Use ouput from:
#
# brew reinstall libtool --verbose --debug | grep curl
#
# You may wnant to clean the homebrew cache first.
ARG LIBTOOL_SHA=dfb94265706b7204b346e3e5d48e149d7c7870063740f0c4ab2d6ec971260517
ARG OSX_CODENAME=big_sur

FROM golang:${GO_VERSION}-bullseye AS base
ARG APT_MIRROR
RUN sed -ri "s/(httpredir|deb).debian.org/${APT_MIRROR:-deb.debian.org}/g" /etc/apt/sources.list \
 && sed -ri "s/(security).debian.org/${APT_MIRROR:-security.debian.org}/g" /etc/apt/sources.list
ENV OSX_CROSS_PATH=/osxcross

FROM base AS osx-sdk
ARG OSX_SDK
# ARG OSX_SDK_SUM
# This is generated from: https://github.com/tpoechtrager/osxcross#packaging-the-sdk
ADD https://storage.googleapis.com/ory.sh/build-assets/${OSX_SDK}.tar.xz "${OSX_CROSS_PATH}/tarballs/${OSX_SDK}.tar.xz"
#RUN echo "${OSX_SDK_SUM}"  "${OSX_CROSS_PATH}/tarballs/${OSX_SDK}.tar.xz" | sha256sum -c -

FROM base AS osx-cross-base
ARG DEBIAN_FRONTEND=noninteractive
# Dependencies for https://github.com/tpoechtrager/osxcross:
# TODO split these into "build-time" and "runtime" dependencies so that build-time deps do not end up in the final image
RUN apt-get update -qq && apt-get install -y -q --no-install-recommends \
    clang \
    file \
    llvm \
    patch \
    xz-utils \
    cmake make libssl-dev lzma-dev libxml2-dev \
    gcc g++ zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev \
 && rm -rf /var/lib/apt/lists/*

FROM osx-cross-base AS osx-cross
ARG OSX_CROSS_COMMIT
WORKDIR "${OSX_CROSS_PATH}"
RUN git clone https://github.com/tpoechtrager/osxcross.git . \
 && git checkout -q "${OSX_CROSS_COMMIT}" \
 && rm -rf ./.git
COPY --from=osx-sdk "${OSX_CROSS_PATH}/." "${OSX_CROSS_PATH}/"
ARG OSX_VERSION_MIN
RUN UNATTENDED=yes OSX_VERSION_MIN=${OSX_VERSION_MIN} ./build.sh

FROM base AS libtool
ARG LIBTOOL_VERSION
ARG LIBTOOL_SHA
ARG OSX_CODENAME
ARG OSX_SDK
RUN mkdir -p "${OSX_CROSS_PATH}/target/SDK/${OSX_SDK}/usr/"

RUN curl -L --globoff --show-error --user-agent Homebrew/3.2.9\ \(Macintosh\;\ Intel\ Mac\ OS\ X\ 11.5.1\)\ curl/7.64.1 --header Accept-Language:\ en --retry 3 --header Authorization:\ Bearer\ QQ== --location --silent --request GET https://ghcr.io/v2/homebrew/core/libtool/blobs/sha256:${LIBTOOL_SHA} --output - \
	| gzip -dc | tar xf - \
		-C "${OSX_CROSS_PATH}/target/SDK/${OSX_SDK}/usr/" \
		--strip-components=2 \
		"libtool/${LIBTOOL_VERSION}/include/" \
		"libtool/${LIBTOOL_VERSION}/lib/"

FROM osx-cross-base AS final
ARG DEBIAN_FRONTEND=noninteractive

RUN curl -fsSL test.docker.com -o get-docker.sh && sh get-docker.sh
RUN curl -sL https://deb.nodesource.com/setup_18.x | bash -s
RUN apt-get update -y \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
    libltdl-dev \
    parallel \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg2 \
    software-properties-common \
    gettext \
    jq \
    build-essential \
    cpp binutils \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

ARG GORELEASER_VERSION=1.14.1
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="arm64" ;; \
        *) echo "unsupported architecture"; exit 1 ;; \
    esac \
    && curl -fsSLO https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}/goreleaser_Linux_${ARCH}.tar.gz \
    && mkdir -p goreleaser_Linux_${ARCH} \
    && tar -xvf goreleaser_Linux_${ARCH}.tar.gz -C goreleaser_Linux_${ARCH} \
    && mv goreleaser_Linux_${ARCH}/goreleaser /usr/local/bin/goreleaser-oss \
    && rm -rf goreleaser_Linux_${ARCH}.* goreleaser_Linux_${ARCH} \
    && curl -fsSLO "https://github.com/goreleaser/goreleaser-pro/releases/download/v${GORELEASER_VERSION}-pro/goreleaser-pro_Linux_${ARCH}.tar.gz" \
    && mkdir -p goreleaser-pro_Linux_${ARCH} \
    && tar -xvf goreleaser-pro_Linux_${ARCH}.tar.gz -C goreleaser-pro_Linux_${ARCH} \
    && mv goreleaser-pro_Linux_${ARCH}/goreleaser /usr/local/bin/goreleaser \
    && rm -rf goreleaser-pro_Linux_${ARCH}.* goreleaser-pro_Linux_${ARCH}

RUN goreleaser --version && goreleaser-oss --version

RUN go install github.com/sigstore/cosign/cmd/cosign@v1.3.0
RUN go install github.com/CycloneDX/cyclonedx-gomod@v1.0.0

COPY --from=osx-cross "${OSX_CROSS_PATH}/." "${OSX_CROSS_PATH}/"
COPY --from=libtool   "${OSX_CROSS_PATH}/." "${OSX_CROSS_PATH}/"
ENV PATH=${OSX_CROSS_PATH}/target/bin:$PATH

# Bump zig version to next stable release once https://github.com/ziglang/zig/issues/3287 is closed
# ARG ZIG_VERSION=0.10.1
# RUN curl -fsSL https://ziglang.org/download/${ZIG_VERSION}/zig-linux-$(arch)-${ZIG_VERSION}.tar.xz | tar -xJ --strip-components=1 -C /usr/local/bin
ARG ZIG_VERSION=0.11.0-dev.1183+2b9478ce1
RUN curl -fsSL https://ziglang.org/builds/zig-linux-$(arch)-${ZIG_VERSION}.tar.xz | tar -xJ --strip-components=1 -C /usr/local/bin
RUN zig version

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
VOLUME /project
WORKDIR /project
RUN git config --global --add safe.directory /project

ENTRYPOINT ["/entrypoint.sh"]
CMD ["-v"]
