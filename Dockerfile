FROM container-registry.oracle.com/database/ords:22.3.2
ADD ./entrypoint.sh /entrypoint.sh
ADD ./apex /opt/oracle/apex/22.2.0
ENV APEX_VER=22.2.0
EXPOSE 8181 27017