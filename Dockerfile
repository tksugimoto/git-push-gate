FROM alpine:3.24

RUN apk add --no-cache git openssh-server openssh-client flock \
 && git config --system safe.directory /srv/git/repo.git \
 && adduser -D -s /bin/sh git && echo 'git:*' | chpasswd -e \
 && mkdir --parents /home/git/.ssh /srv/git && chown --recursive git:git /home/git /srv/git \
 && sed --in-place 's/^Subsystem/#Subsystem/' /etc/ssh/sshd_config \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowUsers git\nDisableForwarding yes\nAllowAgentForwarding no\nClientAliveInterval 30\nClientAliveCountMax 4\n' >> /etc/ssh/sshd_config

COPY hooks/pre-receive /usr/local/share/git-push-gate/pre-receive
COPY bin/git-push-gate bin/unlock /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/local/bin/git-push-gate /usr/local/bin/unlock /entrypoint.sh /usr/local/share/git-push-gate/pre-receive

VOLUME /srv/git
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
