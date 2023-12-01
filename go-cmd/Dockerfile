FROM redis:6.2.5-alpine

#COPY go-cmd /usr/local/bin/entrypoint
ADD go-cmd /usr/local/bin/entrypoint
#RUN ln -s /usr/local/bin/go-cmd /usr/local/bin/entrypoint
RUN ln -s /usr/local/bin/entrypoint /usr/local/bin/healthcheck; \
    ln -s /usr/local/bin/entrypoint /usr/local/bin/appctl;



VOLUME /data
WORKDIR /data

ENTRYPOINT ["entrypoint"]

EXPOSE 6379
