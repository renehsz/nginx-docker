#
# Build Nginx
#
#FROM alpine:3.19 AS builder
FROM debian:12 AS builder

# Set environment variables
ENV MAKEFLAGS="-j$(nproc)"
ENV INSTALLDIR=/opt/nginx

# Install dependencies
#RUN apk add --no-cache \
#    build-base git curl perl cmake \
#    linux-headers pcre-dev libaio-dev
RUN apt-get update && apt-get install -y \
    build-essential git curl cmake \
    zlib1g-dev libzstd-dev libaio-dev libpcre3-dev

# Download and extract everything
WORKDIR /build/nginx
RUN curl -L https://nginx.org/download/nginx-1.27.5.tar.gz | tar xz --strip-components=1
#WORKDIR /opt/zlib-ng
#RUN curl -L https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.1.5.tar.gz | tar xz --strip-components=1
WORKDIR /build/nginx-modules
RUN git clone --recurse-submodules https://github.com/google/ngx_brotli && git -C ngx_brotli reset --hard a71f931
WORKDIR /build/nginx-modules/ngx_zstd
RUN curl -L https://github.com/tokers/zstd-nginx-module/archive/refs/tags/0.1.1.tar.gz | tar xz --strip-components=1
WORKDIR /build/nginx-modules
RUN git clone --recurse-submodules https://github.com/vision5/ngx_devel_kit.git && git -C ngx_devel_kit checkout tags/v0.3.3
RUN git clone --recurse-submodules https://github.com/openresty/lua-nginx-module.git && git -C lua-nginx-module checkout tags/v0.10.28
WORKDIR /build/luajit2
RUN git clone --recurse-submodules https://github.com/openresty/luajit2.git . && git checkout tags/v2.1-20250117
WORKDIR /build/lua-libs/lua-resty-core
RUN curl -L https://github.com/openresty/lua-resty-core/archive/refs/tags/v0.1.31.tar.gz | tar xz --strip-components=1
WORKDIR /build/lua-libs/lua-resty-lrucache
RUN curl -L https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v0.15.tar.gz | tar xz --strip-components=1
WORKDIR /build/lua-libs/lua-cjson
RUN curl -L https://github.com/openresty/lua-cjson/archive/refs/tags/2.1.0.9.tar.gz | tar xz --strip-components=1
WORKDIR /opt/openssl
#RUN curl -L https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz | tar xz --strip-components=1
# TODO: Go back to release once https://github.com/openssl/openssl/pull/24384 is in there
RUN git clone --recurse-submodules https://github.com/openssl/openssl.git . && git checkout d466672
WORKDIR /build/liboqs
RUN curl -L https://github.com/open-quantum-safe/liboqs/archive/refs/tags/0.12.0.tar.gz | tar xz --strip-components=1
WORKDIR /build/oqs-provider
RUN curl -L https://github.com/open-quantum-safe/oqs-provider/archive/refs/tags/0.8.0.tar.gz | tar xz --strip-components=1

# Build and install brotli
WORKDIR /build/nginx-modules/ngx_brotli/deps/brotli/out
RUN cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX=$INSTALLDIR -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_C_FLAGS="-Ofast -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" -DCMAKE_CXX_FLAGS="-Ofast -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" ..
RUN make brotlienc

# Build zlib-ng
#WORKDIR /build/zlib-ng
#RUN ./configure --prefix=$INSTALLDIR --static
#RUN make
#RUN make install
# Apply patches to use zlib-ng for nginx
#WORKDIR /build/nginx
#RUN curl -L https://raw.githubusercontent.com/zlib-ng/patches/297db9814b242f6cb309e1b293d90164a590b4e8/nginx/1.25.3-zlib-ng.patch | patch -p1

# Build and install LuaJIT2
WORKDIR /build/luajit2
RUN make
RUN make install
ENV LUAJIT_LIB=/usr/local/lib
ENV LUAJIT_INC=/usr/local/include/luajit-2.1

# Build and install lua-cjson
WORKDIR /build/lua-libs/lua-cjson
RUN make LUA_INCLUDE_DIR=$LUAJIT_INC
RUN make install

# Build and install OpenSSL
#WORKDIR /opt/openssl
#RUN ./config --prefix=$INSTALLDIR --libdir=lib \
#  no-shared threads no-ssl no-tls1_1 no-afalgeng -lm
#RUN make
#RUN make install_sw install_ssldirs

# Build and install liboqs
WORKDIR /build/liboqs/build
RUN cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX=$INSTALLDIR -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DOQS_USE_OPENSSL=OFF -DOQS_BUILD_ONLY_LIB=ON -DOQS_DIST_BUILD=ON ..
RUN make
RUN make install

# Build and install Nginx
# We cannot link statically because Lua needs to load symbols dynamically. https://github.com/openresty/lua-nginx-module/issues/2106
WORKDIR /build/nginx
RUN ./configure \
    --prefix=$INSTALLDIR \
    --with-cc-opt="-Ofast -flto -fPIE -I$INSTALLDIR/include" \
    --with-ld-opt="-Wl,-rpath,/usr/local/lib -L$INSTALLDIR/lib -flto -pie -Wl,-z,relro -Wl,-z,now" \
    --add-module=/build/nginx-modules/ngx_brotli \
    --add-module=/build/nginx-modules/ngx_zstd \
    --add-module=/build/nginx-modules/ngx_devel_kit \
    --add-module=/build/nginx-modules/lua-nginx-module \
    --with-openssl=/opt/openssl \
    --with-compat \
    --with-file-aio \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_realip_module \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-pcre-jit \
    --with-stream \
    --with-stream_ssl_module \
    --with-threads

    # --with-zlib=/opt/zlib-ng \

RUN make
RUN make install

# Build and install oqs-provider
WORKDIR /build/oqs-provider
ENV OPENSSL_ROOT_DIR="/opt/openssl/.openssl"
RUN liboqs_DIR=$INSTALLDIR cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX=$INSTALLDIR -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -S . -B build
RUN cmake --build build
RUN cp build/lib/* $INSTALLDIR/lib/
RUN ln -s $INSTALLDIR/include/oqs ${OPENSSL_ROOT_DIR}/include && rm -rf build && cmake -DCMAKE_BUILD_TYPE=Release -DOPENSSL_ROOT_DIR=${OPENSSL_ROOT_DIR} -DCMAKE_PREFIX_PATH=$INSTALLDIR -S . -B build && cmake --build build && export MODULESDIR=$(find ${OPENSSL_ROOT_DIR} -name ossl-modules) && cp build/lib/oqsprovider.so $MODULESDIR && mkdir -p ${OPENSSL_ROOT_DIR}/lib64 && ln -s ${OPENSSL_ROOT_DIR}/lib/ossl-modules ${OPENSSL_ROOT_DIR}/lib64 && rm -rf ${INSTALLDIR}/lib64

RUN mkdir -p ${OPENSSL_ROOT_DIR}/ssl/
RUN cp /opt/openssl/apps/openssl.cnf ${OPENSSL_ROOT_DIR}/ssl/
RUN \
    sed -i "s/default = default_sect/default = default_sect\noqsprovider = oqsprovider_sect/g" ${OPENSSL_ROOT_DIR}/ssl/openssl.cnf && \
    sed -i "s/\[default_sect\]/\[default_sect\]\nactivate = 1\n\[oqsprovider_sect\]\nactivate = 1\n/g" ${OPENSSL_ROOT_DIR}/ssl/openssl.cnf && \
    sed -i "s/providers = provider_sect/providers = provider_sect\nssl_conf = ssl_sect\n\n\[ssl_sect\]\nsystem_default = system_default_sect\n\n\[system_default_sect\]\nGroups = \$ENV\:\:DEFAULT_GROUPS\n/g" ${OPENSSL_ROOT_DIR}/ssl/openssl.cnf && \
    sed -i "s/HOME\t\t\t= ./HOME\t\t= .\nDEFAULT_GROUPS\t= ${DEFAULT_GROUPS}/g" ${OPENSSL_ROOT_DIR}/ssl/openssl.cnf

RUN strip ${OPENSSL_ROOT_DIR}/lib/*.a ${OPENSSL_ROOT_DIR}/lib64/ossl-modules/*.so $INSTALLDIR/sbin/*

# get the library out of the architecture-specific directory
RUN cp /usr/lib/`lscpu | awk '/Architecture/{ print $2 }'`-linux-gnu/libpcre.so* /usr/lib/

#
#  Run Nginx
#
FROM debian:12
ENV INSTALLDIR=/opt/nginx

WORKDIR /opt/nginx
COPY --from=builder /opt/openssl/.openssl /opt/openssl/.openssl
COPY --from=builder $INSTALLDIR .
COPY --from=builder /build/lua-libs/lua-resty-core/lib/resty/core ./resty/core
COPY --from=builder /build/lua-libs/lua-resty-core/lib/resty/core.lua ./resty/core.lua
COPY --from=builder /build/lua-libs/lua-resty-lrucache/lib/resty/lrucache ./resty/lrucache
COPY --from=builder /build/lua-libs/lua-resty-lrucache/lib/resty/lrucache.lua ./resty/lrucache.lua
COPY --from=builder /build/lua-libs/lua-cjson/cjson.so /usr/local/lib/lua/5.1/
COPY --from=builder /usr/local/lib/libluajit-5.1.so* /usr/lib/
COPY --from=builder /usr/lib/libpcre.so* /usr/lib/
COPY --from=builder /usr/lib/libzstd.so* /usr/lib/

RUN ln -sf /dev/stdout $INSTALLDIR/logs/access.log && \
    ln -sf /dev/stderr $INSTALLDIR/logs/error.log

# The default config causes Nginx to crash on startup for unknown reasons... so we'll just delete it for now
RUN rm -f /opt/openssl/.openssl/ssl/openssl.cnf

# From nginx 1.25.2: "nginx does not try to load OpenSSL configuration if the --with-openssl option was used to built OpenSSL and the OPENSSL_CONF environment variable is not set".
# We therefore have to set the OPENSSL_CONF environment variable.
ENV OPENSSL_CONF="/opt/openssl/.openssl/ssl/openssl.cnf"

EXPOSE 80 443

CMD ["/opt/nginx/sbin/nginx", "-c", "nginx-conf/nginx.conf", "-g", "daemon off;"]

