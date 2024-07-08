.PHONY: run gencert build-image push-image

run:
	docker-compose up --build --force-recreate --no-deps

gencert:
	mkdir -p certs/cacert certs/pki
	docker run --rm -it -v ./certs:/work -w /work openquantumsafe/oqs-ossl3 sh -c '\
		openssl req -x509 -new -newkey dilithium3 -keyout CA.key -out cacert/CA.crt -nodes -subj "/CN=oqstest CA" -days 365 && \
		openssl req -new -newkey dilithium3 -keyout pki/server.key -out server.csr -nodes -subj "/CN=oqs-nginx" && \
		openssl x509 -req -in server.csr -out pki/server.crt -CA cacert/CA.crt -CAkey CA.key -CAcreateserial -days 365 && \
		echo Done.'

build-image:
	docker buildx build --load -t renehsz/nginx:latest --platform linux/amd64,linux/arm64 .

push-image:
	docker image push renehsz/nginx:latest

