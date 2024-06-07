FROM mcr.microsoft.com/mirror/docker/library/alpine:3.16

# Install samba
RUN apk --no-cache --no-progress upgrade && \
    apk --no-cache --no-progress add bash coreutils samba shadow tini tzdata && \
    addgroup -S smb && \
    adduser -S -D -H -h /tmp -s /sbin/nologin -G smb -g 'Samba User' smbuser

COPY src/core-fileserver.sh /
COPY src/templates /templates
COPY src/docker-entrypoint.sh /
COPY src/smb.conf /etc/samba/smb.conf

RUN chmod 764 /core-fileserver.sh
RUN chmod 764 /docker-entrypoint.sh

EXPOSE 137/udp 138/udp 139 445

HEALTHCHECK --interval=60s --timeout=15s \
            CMD smbclient -L \\localhost -U % -m SMB3

VOLUME ["/etc", "/var/cache/samba", "/var/lib/samba", "/var/log/samba",\
            "/run/samba"]

ENTRYPOINT ["/docker-entrypoint.sh"]