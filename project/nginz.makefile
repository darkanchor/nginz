.PHONY: copy clean all

all: ./submodules/nginx/objs/nginz.c

./submodules/nginx/objs/ngx_modules.c:
	cd submodules/nginx && ./auto/configure \
		--with-compat \
		--with-file-aio \
		--with-threads \
		--with-http_ssl_module \
		--with-http_xslt_module \
		--with-http_v2_module \
		--with-http_v3_module \
		--with-debug
	cd submodules/njs && ./configure

copy: ./submodules/nginx/src/core/nginx.c ./submodules/nginx/objs/ngx_modules.c
	cp ./submodules/nginx/src/core/nginx.c ./submodules/nginx/objs/nginz.c

./submodules/nginx/objs/nginz.c: copy
	patch --batch -N ./submodules/nginx/objs/nginz.c < project/nginz.patch || grep -Fq 'main_nginx(int argc, char *const *argv)' ./submodules/nginx/objs/nginz.c

clean:
	rm -f ./submodules/nginx/objs/ngx_modules.c ./submodules/nginx/objs/nginz.c
