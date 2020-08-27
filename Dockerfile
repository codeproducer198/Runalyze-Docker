ARG CONF_REGISTRY
ARG CONF_TAG
FROM ${CONF_REGISTRY}/base:${CONF_TAG}

MAINTAINER codeproducer198

ARG CONF_USER=dockusr
ARG CONF_APP_ROOT=/app/runalyze

# Specifies about of this dockerfile/installation
# - the release artefact is stored in the GIT repository
# - download of the timezone correction database (wget -O ./data/timezone.sqlite https://cdn.runalyze.com/update/timezone.sqlite) not done in docker, because it is part of the source/GIT-repository
# - "restart" queue-processing with a cron-job periodically
# - the best method to provide the SRTM data is via a docker volume to '$CONF_APP_ROOT/data/srtm'

RUN apt-get update \
	&& apt-get install -y --no-install-recommends nginx php7.3-fpm \
	&& apt-get install -y --no-install-recommends php7.3-intl php7.3-mysql php7.3-mbstring php7.3-xml php7.3-curl php7.3-zip php7.3-gettext \
													# sqlite for timezones
													php7.3-sqlite3 sqlite3 libsqlite3-mod-spatialite \
	&& apt-get install -y --no-install-recommends perl gettext libxml2 python3 python3-pip python3-setuptools inkscape \
	&& apt-get install -y --no-install-recommends librsvg2-bin librsvg2-common \
	&& apt-get install -y --no-install-recommends locales && echo "de_DE.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen \
	# install python dependencies for poster generation (all from vendor/runalyze/GpxTrackPoster/requirements.txt); i don't use "-r requirements.txt" because this is not yet available
	&& pip3 install --no-cache-dir appdirs==1.4.0 gpxpy==1.0.0 pyparsing==2.0.7 svgwrite==1.1.6 \
	&& apt-get clean && rm -rf /var/lib/apt/lists/*

# nginx site
COPY config/nginx/ /etc/nginx/

COPY runit/ /etc/service/

# nginx and php configuration
RUN phpdismod mysqli \
	# activate site and remove default
	&& ln -s /etc/nginx/sites-available/nginxRunalyze /etc/nginx/sites-enabled/nginxRunalyze \
	&& rm -r /etc/nginx/sites-enabled/default \
	# optimize nginx
	&& sed -E -i 's|(^.*)#.*server_tokens.*;$|\1server_tokens off;|' 					/etc/nginx/nginx.conf \
	&& sed -E -i 's|(^.*worker_processes\s+)(.*)(\s*;)$|\12\3|' 						/etc/nginx/nginx.conf \
	# symlink to start php without version
	&& ln -s /usr/sbin/php-fpm7.3 /usr/sbin/php-fpm \
	# aus irgendwelchen gruenden ist das verzeichnis nicht von anfang an da - hier also anlegen
	&& mkdir -p /run/php/ \
	# ich habe es nicht vernuenftig hinbekommen, die dateien direkt ueber ein volume zu mounten
	&& sed -E -i 's#^error_log\s+=.*$#error_log = /var/log/runalyze/php-fpm.log#' 		/etc/php/7.3/fpm/php-fpm.conf \
	&& sed -E -i 's#^/var/log/php7.3-fpm.log#/var/log/runalyze/php-fpm.log#' 			/etc/logrotate.d/php7.3-fpm \
	&& sed -E -i 's#^listen\s+=.*$#listen = /var/run/php/php-fpm.sock#' 				/etc/php/7.3/fpm/pool.d/www.conf \
	# optimierung php-fpm auf speicherverbrauch
	&& sed -E -i 's#^pm\s+=.*$#pm = ondemand#' 											/etc/php/7.3/fpm/pool.d/www.conf \
	&& sed -E -i 's#^;*pm.process_idle_timeout\s+=.*$#pm.process_idle_timeout = 25s#' 	/etc/php/7.3/fpm/pool.d/www.conf \
	# increase execition timeout (see also value in nginx config)
	&& sed -E -i 's#^max_execution_time\s+=.*$#max_execution_time = 300#' 				/etc/php/7.3/fpm/php.ini \
	# set memory (128M is default)
	&& sed -E -i 's#^memory_limit\s+=.*$#memory_limit = 128M#'			 				/etc/php/7.3/fpm/php.ini \
	# change to running user from www-data to dockusr
	&& sed -E -i 's#^((user|group|listen\.owner|listen\.group)\s+=).*$#\1'$CONF_USER'#'	/etc/php/7.3/fpm/pool.d/www.conf \
	&& sed -E -i 's|(^.*user\s+)(.*)(\s*;)$|\1'$CONF_USER'\3|' 							/etc/nginx/nginx.conf \
	# change run user of queue start
	&& sed    -i 's#${RUN_USER}#'$CONF_USER'#' 											/etc/service/queue/run

# prepare runalyze
RUN	mkdir /app \
	&& chown -R $CONF_USER:$CONF_USER -R /app \
	# add queue start as cron (job is started and stopped itself)
	&& echo "# runalyze batch/queue processing\n* */4 * * * root sv start queue > /dev/null" > /etc/cron.d/runalyzequeue && chmod 600 /etc/cron.d/runalyzequeue

WORKDIR /app

USER $CONF_USER

# download runalyze and extract it
RUN echo "Downloading..." && curl -L -s https://github.com/codeproducer198/Runalyze/archive/master.zip --output /app/master.zip \
	&& echo "Unziping..." && unzip -q /app/master.zip -d /app \
	&& echo "Move..." && mv /app/Runalyze-master $CONF_APP_ROOT \
	&& echo "Remove..." && rm /app/master.zip

# copy and protect the configuration file
COPY --chown=$CONF_USER:$CONF_USER config/config.yml $CONF_APP_ROOT/data/config.yml
RUN chmod 600 $CONF_APP_ROOT/data/config.yml

COPY entrypoint.sh .

USER root

# Start to prepare the running container
ENTRYPOINT ["/app/entrypoint.sh"]

# Start CMD using runi
CMD ["/usr/local/sbin/runit_init.sh"]
