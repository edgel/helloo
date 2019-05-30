FROM openjdk:8-jre-alpine

ENV CATALINA_HOME /usr/local/tomee
ENV PATH $CATALINA_HOME/bin:$PATH
RUN mkdir -p "$CATALINA_HOME"
WORKDIR $CATALINA_HOME

# let "Tomcat Native" live somewhere isolated
ENV TOMCAT_NATIVE_LIBDIR $CATALINA_HOME/native-jni-lib
ENV LD_LIBRARY_PATH ${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$TOMCAT_NATIVE_LIBDIR

# curl -fsSL 'https://www.apache.org/dist/tomee/KEYS' | awk -F ' = ' '$1 ~ /^ +Key fingerprint$/ { gsub(" ", "", $2); print $2 }' | sort -u
ENV GPG_KEYS  \
    223D3A74B068ECA354DC385CE126833F9CF64915 \
    678F2D98F1FD9643811639FB622B8F2D043F71D8 \
    7A2744A8A9AAF063C23EB7868EBE7DBE8D050EEF \
    82D8419BA697F0E7FB85916EE91287822FDB81B1 \
    9056B710F1E332780DE7AF34CBAEBE39A46C4CA1 \
    A57DAF81C1B69921F4BA8723A8DE0A4DB863A7C1 \
    B7574789F5018690043E6DD9C212662E12F3E1DD \
    B8B301E6105DF628076BD92C5483E55897ABD9B9 \
    BDD0BBEB753192957EFC5F896A62FC8EF17D8FEF \
    C23A3F6F595EBD0F960270CC997C8F1A5BE6E4C1 \
    D11DF12CC2CA4894BDE638B967C1227A2678363C \
    DBCCD103B8B24F86FFAAB025C8BB472CD297D428 \
    F067B8140F5DD80E1D3B5D92318242FE9A0B1183 \
    FAA603D58B1BA4EDF65896D0ED340E0E6D545F97

ENV TOMCAT_TGZ_URLS \
	http://maven.aliyun.com/nexus/content/groups/public/org/apache/tomee/apache-tomee/7.1.0/apache-tomee-7.1.0-plume.tar.gz

ENV TOMCAT_ASC_URLS \
	http://maven.aliyun.com/nexus/content/groups/public/org/apache/tomee/apache-tomee/7.1.0/apache-tomee-7.1.0-plume.tar.gz.asc

RUN set -eux; \
	success=; \
	for url in $TOMCAT_TGZ_URLS; do \
		if wget -O tomee.tar.gz "$url"; then \
			success=1; \
			break; \
		fi; \
	done; \
	[ -n "$success" ]; \
	\
	success=; \
	for url in $TOMCAT_ASC_URLS; do \
		if wget -O tomee.tar.gz.asc "$url"; then \
			success=1; \
			break; \
		fi; \
	done; \
	[ -n "$success" ]; 

RUN set -eux; \
	\
	apk add --no-cache --virtual .fetch-deps \
		gnupg \
		\
		ca-certificates \
		openssl \
	; \
	\
	export GNUPGHOME="$(mktemp -d)"; \
	for key in $GPG_KEYS; do \
		gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
	done; \
  gpg --batch --verify tomee.tar.gz.asc tomee.tar.gz; \
	tar -xvf tomee.tar.gz --strip-components=1; \
	pwd; ls -l; \
	rm bin/*.bat; \
	rm tomee.tar.gz*; \
	command -v gpgconf && gpgconf --kill all || :; \
	rm -rf "$GNUPGHOME"; 

RUN set -eux; \
	nativeBuildDir="$(mktemp -d)"; \
	tar -xvf bin/tomcat-native.tar.gz -C "$nativeBuildDir" --strip-components=1; \
	apk add --no-cache --virtual .native-build-deps \
		apr-dev \
		coreutils \
		dpkg-dev dpkg \
		gcc \
		libc-dev \
		make \
		"openjdk${JAVA_VERSION%%[-~bu]*}"="$JAVA_ALPINE_VERSION" \
		openssl-dev \
	; \
	( \
		export CATALINA_HOME="$PWD"; \
		cd "$nativeBuildDir/native"; \
		gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
		./configure \
			--build="$gnuArch" \
			--libdir="$TOMCAT_NATIVE_LIBDIR" \
			--prefix="$CATALINA_HOME" \
			--with-apr="$(which apr-1-config)" \
			--with-java-home="$(docker-java-home)" \
			--with-ssl=yes; \
		make -j "$(nproc)"; \
		make install; \
	); \
	rm -rf "$nativeBuildDir"; \
	rm bin/tomcat-native.tar.gz; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive "$TOMCAT_NATIVE_LIBDIR" \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --virtual .tomcat-native-rundeps $runDeps; \
	apk del .fetch-deps .native-build-deps; \
	\
# sh removes env vars it doesn't support (ones with periods)
# https://github.com/docker-library/tomcat/issues/77
	apk add --no-cache bash; \
	find ./bin/ -name '*.sh' -exec sed -ri 's|^#!/bin/sh$|#!/usr/bin/env bash|' '{}' +; \
	\
# fix permissions (especially for running as non-root)
# https://github.com/docker-library/tomcat/issues/35
	chmod -R +rX .; \
	chmod 777 logs work

# verify Tomcat Native is working properly
RUN set -e \
	&& nativeLines="$(catalina.sh configtest 2>&1)" \
	&& nativeLines="$(echo "$nativeLines" | grep 'Apache Tomcat Native')" \
	&& nativeLines="$(echo "$nativeLines" | sort -u)" \
	&& if ! echo "$nativeLines" | grep 'INFO: Loaded APR based Apache Tomcat Native library' >&2; then \
		echo >&2 "$nativeLines"; \
		exit 1; \
	fi

EXPOSE 8080
CMD ["catalina.sh", "run"]
