FROM alpine:3.20
RUN apk add --no-cache bash curl jq util-linux-misc ca-certificates coreutils
COPY usenetspy.sh /usr/local/bin/usenetspy.sh
RUN chmod +x /usr/local/bin/usenetspy.sh
ENTRYPOINT ["/usr/local/bin/usenetspy.sh"]
