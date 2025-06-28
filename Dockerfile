#
# Build Nginx
#
FROM debian:12 AS builder

# Set environment variables
ENV MAKEFLAGS="-j$(nproc)"
ENV INSTALLDIR=/opt/nginx

# Install dependencies
RUN apt-get update && apt-get install -y \
    build-essential git curl python3 cmake \
    zlib1g-dev libzstd-dev libaio-dev libpcre3-dev

# Download and extract everything
WORKDIR /build/nginx
RUN curl -L https://nginx.org/download/nginx-1.29.0.tar.gz | tar xz --strip-components=1
WORKDIR /build/aws-lc
RUN curl -L https://github.com/aws/aws-lc/archive/refs/tags/v1.54.0.tar.gz | tar xz --strip-components=1
WORKDIR /build/nginx-modules
RUN git clone --recurse-submodules https://github.com/google/ngx_brotli && git -C ngx_brotli reset --hard a71f931
WORKDIR /build/nginx-modules/ngx_zstd
RUN curl -L https://github.com/tokers/zstd-nginx-module/archive/refs/tags/0.1.1.tar.gz | tar xz --strip-components=1
WORKDIR /build/nginx-modules/headers-more
RUN curl -L https://github.com/openresty/headers-more-nginx-module/archive/refs/tags/v0.38.tar.gz | tar xz --strip-components=1
WORKDIR /build/nginx-modules
RUN git clone --recurse-submodules https://github.com/vision5/ngx_devel_kit.git && git -C ngx_devel_kit checkout tags/v0.3.3
RUN git clone --recurse-submodules https://github.com/openresty/lua-nginx-module.git && git -C lua-nginx-module checkout tags/v0.10.28
WORKDIR /build/luajit2
RUN git clone --recurse-submodules https://github.com/openresty/luajit2.git . && git checkout tags/v2.1-20250529
WORKDIR /build/lua-libs/lua-resty-core
RUN curl -L https://github.com/openresty/lua-resty-core/archive/refs/tags/v0.1.31.tar.gz | tar xz --strip-components=1
WORKDIR /build/lua-libs/lua-resty-lrucache
RUN curl -L https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v0.15.tar.gz | tar xz --strip-components=1
WORKDIR /build/lua-libs/lua-cjson
RUN curl -L https://github.com/openresty/lua-cjson/archive/refs/tags/2.1.0.9.tar.gz | tar xz --strip-components=1

# Build and install AWS-LC
WORKDIR /build/aws-lc/build
RUN cmake -G "Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX=$INSTALLDIR -DCMAKE_BUILD_TYPE=Release \
    -DDISABLE_GO=ON -DBUILD_TESTING=OFF -DBUILD_TOOL=OFF \
    ..
RUN cmake --build .
RUN cmake --install .

# Patch lua-nginx-module to not include SSL stuff because it doesn't work with AWS-LC yet...
# TODO: Remove this once AWS-LC support is merged: https://github.com/openresty/lua-nginx-module/pull/2357
WORKDIR /build/nginx-modules/lua-nginx-module
RUN sed -i 's/NGX_HTTP_SSL/NGX_HTTP_SSL_YESSIR/g' $(find . -type f -name "*.c" -or -type f -name "*.h")

# Build and install brotli module
WORKDIR /build/nginx-modules/ngx_brotli/deps/brotli/out
RUN cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX=$INSTALLDIR -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_C_FLAGS="-Ofast -flto -pie -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections -Wl,-z,relro -Wl,-z,now" -DCMAKE_CXX_FLAGS="-Ofast -flto -pie -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections -Wl,-z,relro -Wl,-z,now" ..
RUN make -j$(getconf _NPROCESSORS_ONLN) brotlienc

# Build and install LuaJIT2
WORKDIR /build/luajit2
RUN make -j$(getconf _NPROCESSORS_ONLN)
RUN make -j$(getconf _NPROCESSORS_ONLN) install
ENV LUAJIT_LIB=/usr/local/lib
ENV LUAJIT_INC=/usr/local/include/luajit-2.1

# Build and install lua-cjson
WORKDIR /build/lua-libs/lua-cjson
RUN make -j$(getconf _NPROCESSORS_ONLN) LUA_INCLUDE_DIR=$LUAJIT_INC
RUN make -j$(getconf _NPROCESSORS_ONLN) install

# Build and install Nginx
#
# We cannot link statically because Lua needs to load symbols dynamically. https://github.com/openresty/lua-nginx-module/issues/2106
#
# We add the brotli module after the zstd module because we prefer it for its slightly better compression ratio.
# See https://github.com/tokers/zstd-nginx-module/issues/40
#
WORKDIR /build/nginx
RUN patch -p1 </build/aws-lc/tests/ci/integration/nginx_patch/aws-lc-nginx.patch
RUN ./configure \
    --prefix=$INSTALLDIR \
    \
    --with-cc-opt="-Ofast -flto -pie -I$INSTALLDIR/include" \
    --with-ld-opt="-Wl,-rpath,/usr/local/lib -L$INSTALLDIR/lib -flto -pie -Wl,-z,relro -Wl,-z,now" \
    \
    --add-module=/build/nginx-modules/ngx_zstd \
    --add-module=/build/nginx-modules/ngx_brotli \
    --add-module=/build/nginx-modules/headers-more \
    --add-module=/build/nginx-modules/ngx_devel_kit \
    --add-module=/build/nginx-modules/lua-nginx-module \
    \
    --with-compat \
    --with-file-aio \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_realip_module \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-pcre-jit \
    --with-pcre-opt="-O3" \
    --with-stream \
    --with-stream_ssl_module \
    --with-threads

RUN make -j$(getconf _NPROCESSORS_ONLN)
RUN make -j$(getconf _NPROCESSORS_ONLN) install

# get the library out of the architecture-specific directory
RUN cp /usr/lib/`lscpu | awk '/Architecture/{ print $2 }'`-linux-gnu/libpcre.so* /usr/lib/

#
#  Run Nginx
#
FROM debian:12
ENV INSTALLDIR=/opt/nginx

WORKDIR /opt/nginx
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

EXPOSE 80/tcp 443/tcp 443/udp

CMD ["/opt/nginx/sbin/nginx", "-c", "nginx-conf/nginx.conf", "-g", "daemon off;"]

