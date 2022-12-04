#!/bin/bash
# Copyright (c) 2021, Oracle and/or its affiliates. All rights reserved.
#
#    NAME
#        entrypoint.sh
#
#    DESCRIPTION
#        Script to configured and israt APEX and ORDS on a container
#    NOTES

#
#    CHANGE LOG
#        MODIFIED    VERSION    (MM/DD/YY)
#        admuro      1.0.0       08/24/21 - Script Creation
#        admuro      1.1.0       02/13/22 - Change name to entrypoint,
#                                           Adding ssl case.
#                                           and adding ords_entrypoint_dir funtion.
#        admuro      1.2.0       05/02/22 - Updates for ORDS 22.1.0
ORDS_HOME=/opt/oracle/ords
APEX_HOME=/opt/oracle/apex/$APEX_VER
APEXI=/opt/oracle/apex/images/$APEX_VER
INSTALL_LOGS=/tmp/install_container.log
CONN_STRING_FILE_DIR=/opt/oracle/variables
CONN_STRING_FILE_NAME=conn_string.txt
CONN_STRING_FILE="$CONN_STRING_FILE_DIR"/"$CONN_STRING_FILE_NAME"
ORDS_ENTRYPOINT_DIR=/ords-entrypoint.d/
ORDS_CONF_DIR="/etc/ords/config"
export http_proxy= 
export https_proxy= 
export no_proxy= 
export HTTP_PROXY= 
export HTTPS_PROXY= 
export NO_PROXY=
printf "%s%s\n" "INFO : " "This container will start a service running ORDS $ORDS_VER and APEX $APEX_VER."
### Validate variable
function conn_string() {
	if  [ -e $CONN_STRING_FILE ]; then
		source $CONN_STRING_FILE
		if [ -n "$CONN_STRING" ];then
			printf "%s%s\n" "INFO : " "CONN_STRING has been found in the container variables file."
		else
			printf "\a%s%s\n" "ERROR: " "CONN_STRING has not found in the container variables file."
			printf "%s%s\n"   "       " "   user/password@hostname:port/service_name        "
			exit 1
		fi
	else
		printf "\a%s%s\n" "ERROR: " "CONN_STRING_FILE has not added, create a file with CONN_STRING variable and added as docker volume:"
		printf "%s%s\n"   "       " "   mkdir volume ; echo 'CONN_STRING="user/password@hostname:port/service_name"' > volume/$CONN_STRING_FILE_NAME"
		exit 1
	fi
	
	export DB_USER=$(echo $CONN_STRING| awk -F"@" '{print $1}'|awk -F"/" '{print $1}')
	export DB_PASS=$(echo $CONN_STRING| awk -F"@" '{print $1}'|awk -F"/" '{print $2}')
	export DB_HOST=$(echo $CONN_STRING| awk -F"@" '{print $2}'|awk -F":" '{print $1}')
	export DB_PORT=$(echo $CONN_STRING| awk -F"@" '{print $2}'|awk -F":" '{print $2}'|awk -F"/" '{print $1}')
	export DB_NAME=$(echo $CONN_STRING| awk -F"@" '{print $2}'|awk -F":" '{print $2}'|awk -F"/" '{print $2}')
}
# Test DB connection
function testDB() {
	conn_string
	sql /nolog << _SQL_SCRIPT &>> $INSTALL_LOGS
	whenever sqlerror exit failure
	whenever oserror exit failure
	conn $CONN_STRING as sysdba
	select 'success' from dual;
	exit
_SQL_SCRIPT
	RESULT=$?
	if [ ${RESULT} -eq 0 ] ; then
		printf "%s%s\n" "INFO : " "Database connection established."
		rm $CONN_STRING_FILE
	else
		printf "\a%s%s\n" "ERROR: " "Cannot connect to database please validate CONN_STRING has below shape:"
		printf "%s%s\n"   "       " "   user/password@hostname:port/service_name                            "
		exit 1
	fi
}

function apex_remove() {
	### Remove old installations
	cd $APEX_HOME
	sql /nolog << _SQL_SCRIPT &>> $INSTALL_LOGS
	conn $CONN_STRING as sysdba
	alter session set container=$DB_NAME;
	alter session set "_oracle_script"=true;
	@apxremov.sql
_SQL_SCRIPT
	RESULT=$?
	if [ ${RESULT} -eq 0 ] ; then
		printf "%s%s\n" "INFO : " "Database connection established."
	else
		printf "\a%s%s\n" "ERROR: " "Cannot connect to database."
		exit 1
	fi
}

function apex() {
	# Validate if apex is instaled and the version
	sql -s /nolog << _SQL_SCRIPT > /tmp/apex_version 2> /dev/null
	conn $CONN_STRING as sysdba
	SET LINESIZE 20000 TRIM ON TRIMSPOOL ON
	SET PAGESIZE 0
	SELECT VERSION FROM DBA_REGISTRY WHERE COMP_ID='APEX';
_SQL_SCRIPT
	# Get RPM installed version
	YEAR=$(echo $APEX_VER | cut -d"." -f1)
	QTR=$(echo $APEX_VER | cut -d"." -f2)
	PATCH=$(echo $APEX_VER| cut -d"." -f3)
	# Get DB installed version
	APEX_DBVER=$(cat /tmp/apex_version|grep [0-9][0-9].[1-5].[0-9] |sed '/^$/d'|sed 's/ //g')
	DB_YEAR=$(echo $APEX_DBVER | cut -d"." -f1)
	DB_QTR=$(echo $APEX_DBVER | cut -d"." -f2)
	DB_PATCH=$(echo $APEX_DBVER| cut -d"." -f3)
	
	grep "SQL Error" /tmp/apex_version > /dev/null
	_sql_error=$?
	if [ ${_sql_error} -eq 0 ] ; then
		printf "\a%s%s\n" "ERROR: " "Please validate the database status."
		grep "SQL Error" /tmp/apex_version 
		exit 1
	fi
	if [ -n "$APEX_DBVER" ]; then
		# Validate if an upgrade needed
		if [ "$APEX_DBVER" = "$APEX_VER" ]; then
			printf "%s%s\n" "INFO : " "APEX $APEX_VER is already installed in your database."
			export INS_STATUS="INSTALLED"
		elif [ $DB_YEAR -gt $YEAR ]; then
			printf "\a%s%s\n" "ERROR: " "A newer APEX version ($APEX_DBVER) is already installed in your database. The APEX version in this container is $APEX_VER. Stopping the container." 
			exit 1
		elif [ $DB_YEAR -eq $YEAR ] && [ $DB_QTR -gt $QTR ]; then
			printf "\a%s%s\n" "ERROR: " "A newer APEX version ($APEX_DBVER) is already installed in your database. The APEX version in this container is $APEX_VER. Stopping the container."
			exit 1
		elif [ $DB_YEAR -eq $YEAR ] && [ $DB_QTR -eq $QTR ] && [ $DB_PATCH -gt $PATCH ]; then
			printf "\a%s%s\n" "ERROR: " "A newer APEX version ($APEX_DBVER) is already installed in your database. The APEX version in this container is $APEX_VER. Stopping the container."
			exit 1
		else
			printf "%s%s\n" "INFO : " "Your have installed APEX ($APEX_DBVER) on you database but will be upgraded to $APEX_VER."
			export INS_STATUS="UPGRADE"
			apex_install
			apex_config
		fi
	else
		printf "%s%s\n" "INFO : " "Apex is not installed on your database."
		export INS_STATUS="FRESH"
		apex_install
		apex_config
	fi
}

function apex_install() {
	if [ -f $APEX_HOME/apexins.sql ]; then
		printf "%s%s\n" "INFO : " "Installing APEX on your DB please be patient."
		printf "%s%s\n" "INFO : " "You can check the logs by running the command below in a new terminal window:"
		printf "%s%s\n" "       " "	docker exec -it $HOSTNAME tail -f $INSTALL_LOGS"
		printf "%s%s\n" "WARN : " "APEX can be installed remotely on PDBs, If you want to install it on a CDB,"
		printf "%s%s\n" "       " "install it directly on the Database and not remotely."
		cd $APEX_HOME
		sql /nolog << _SQL_SCRIPT  &>> $INSTALL_LOGS
		conn $CONN_STRING as sysdba
		select user from dual;
		@apexins SYSAUX SYSAUX TEMP /i/
		@apex_rest_config_core.sql /opt/oracle/apex/$APEX_VER/ oracle oracle
_SQL_SCRIPT
		RESULT=$?
		if [ ${RESULT} -eq 0 ] ; then
			printf "%s%s\n" "INFO : " "APEX has been installed."
		else
			printf "\a%s%s\n" "ERROR: " "APEX installation failed"
			exit 1
		fi
	else
		printf "\a%s%s\n" "ERROR: " "APEX installation script missing."
	fi
}
function apex_password() {
	if [[ ${INS_STATUS} == "FRESH" ]] ; then
		# Set ADMIN passsword to Welcome_1
		cd $APEX_HOME
		cp /opt/oracle/apex/setapexadmin.sql .
		sql /nolog << _SQL_SCRIPT &>> $INSTALL_LOGS
		conn $CONN_STRING as sysdba
		alter session set container=$DB_NAME;
		@setapexadmin.sql
_SQL_SCRIPT
		sql /nolog << _SQL_SCRIPT >> $INSTALL_LOGS
		conn $CONN_STRING as sysdba
		alter session set container=$DB_NAME;
		DECLARE 
		l_user_id NUMBER;
		BEGIN
			APEX_UTIL.set_workspace(p_workspace => 'INTERNAL');
			l_user_id := APEX_UTIL.GET_USER_ID('ADMIN');
			APEX_UTIL.EDIT_USER(p_user_id => l_user_id, p_user_name  => 'ADMIN', p_change_password_on_first_use => 'N');
		END;
_SQL_SCRIPT
		RESULT=$?
		if [ ${RESULT} -eq 0 ] ; then
			printf "%s%s\n" "INFO : " "APEX ADMIN password has configured as 'Welcome_1'."
			printf "%s%s\n" "INFO : " "Use below login credentials to first time login to APEX service:"
			printf "%s%s\n" "       " "	Workspace: internal"
			printf "%s%s\n" "       " "	User:      ADMIN"
			printf "%s%s\n" "       " "	Password:  Welcome_1"
		else
			printf "\a%s%s\n" "ERROR : " "APEX Configuration failed."
		exit 1
		fi
	else 
		printf "%s%s\n" "INFO : " "APEX was updated but your previous ADMIN password was not affected."
	fi	
}

function apex_config() {
	printf "%s%s\n" "INFO : " "Configuring APEX."
	sql /nolog << _SQL_SCRIPT  &>> $INSTALL_LOGS
	conn $CONN_STRING as sysdba
	alter session set container=$DB_NAME;
	alter profile default limit password_life_time UNLIMITED;
	ALTER USER APEX_PUBLIC_USER ACCOUNT UNLOCK;
	ALTER USER APEX_PUBLIC_USER IDENTIFIED BY oracle;
	BEGIN
            apex_instance_admin.set_parameter(
                p_parameter => 'IMAGE_PREFIX',
                p_value     => 'https://static.oracle.com/cdn/apex/22.2.0/' );      
            commit;
	END;
	exit
_SQL_SCRIPT
	RESULT=$?
	if [ ${RESULT} -eq 0 ] ; then
		printf "%s%s\n" "INFO : " "APEX_PUBLIC_USER has been configured as oracle."
	else
		printf "\a%s%s\n" "ERROR : " "APEX Configuration failed."
		exit 1
	fi
	apex_password
}

function install_ords() {
	printf "%s%s\n" "INFO : " "Preparing ORDS."
	# Randomize the password for all the ORDS connection pool accounts
	PASSWD=oracle
	cd $ORDS_CONF_DIR
	ords install --admin-user SYS --proxy-user --password-stdin --db-hostname $DB_HOST \
	--db-port $DB_PORT --db-servicename $DB_NAME --feature-sdw true --log-folder /tmp/ords_logs/install_logs_DB${DBVERSION}  << SECRET
${DB_PASS}
oracle
SECRET
}

function ords_entrypoint_dir() {
	if [ -d ${ORDS_ENTRYPOINT_DIR} ] ; then
		ls -la ${ORDS_ENTRYPOINT_DIR}/*.sh > /dev/null
		EXIST=$?
		if [ $EXIST -gt 0 ]; then
			printf "%s%s\n" "INFO : " "No custom scripts were detected to run before starting ORDS service."
		else
			printf "%s%s\n" "INFO : " "Files with extensions .sh, were found in ${ORDS_ENTRYPOINT_DIR}. Files will be executed in alphabetical order."
			for script in $(ls -L $ORDS_ENTRYPOINT_DIR/*.sh | sort); do
				printf "%s%s\n" "INFO : " "Excecuting script ${script}."
				bash ${script}
			done
		fi
	fi
}

function config_sdw() {
	grep invalidPoolTimeout $ORDS_CONF_DIR/global/settings.xml > /dev/null
	if [ $? -eq 1 ]; then
		printf "%s%s\n" "INFO : " "Configuring db.invalidPoolTimeout 5s"
		ords --config $ORDS_CONF_DIR config set db.invalidPoolTimeout 5s
	fi
	grep mongo.enabled $ORDS_CONF_DIR/global/settings.xml > /dev/null
	if [ $? -eq 1 ]; then
		printf "%s%s\n" "INFO : " "Configuring mongo.enabled true"
		ords --config $ORDS_CONF_DIR config set mongo.enabled true
	fi
	grep invalidPoolTimeout $ORDS_CONF_DIR/global/settings.xml > /dev/null
	if [ $? -eq 1 ]; then
		printf "%s%s\n" "INFO : " "Configuring db.invalidPoolTimeout 5s"
		ords --config $ORDS_CONF_DIR config set db.invalidPoolTimeout 5s
	fi
	grep restEnabledSql $ORDS_CONF_DIR/databases/default/pool.xml > /dev/null
	if [ $? -eq 1 ]; then
		printf "%s%s\n" "INFO : " "Configuring restEnabledSql.active true"
		ords --config $ORDS_CONF_DIR config set restEnabledSql.active true
	fi
	grep feature.sdw $ORDS_CONF_DIR/databases/default/pool.xml > /dev/null
	if [ $? -eq 1 ]; then
		printf "%s%s\n" "INFO : " "Configuring feature.sdw true"
		ords --config $ORDS_CONF_DIR config set feature.sdw true
	fi
	grep jdbc.MaxLimit $ORDS_CONF_DIR/databases/default/pool.xml > /dev/null
	if [ $? -eq 1 ]; then
		printf "%s%s\n" "INFO : " "Configuring jdbc.MaxLimit 30"
		ords --config $ORDS_CONF_DIR config set jdbc.MaxLimit 30
	fi
	grep jdbc.InitialLimit $ORDS_CONF_DIR/databases/default/pool.xml > /dev/null
	if [ $? -eq 1 ]; then
		printf "%s%s\n" "INFO : " "Configuring jdbc.InitialLimit 10"
		ords --config $ORDS_CONF_DIR config set jdbc.InitialLimit 10
	fi
}

function run_ords() {
	ords_entrypoint_dir
	config_sdw	
	if [ -e $ORDS_CONF_DIR/databases/default/pool.xml ]; then
		DB_HOST=$(grep db.hostname $ORDS_CONF_DIR/databases/default/pool.xml|cut -d">" -f2|cut -d"<" -f1)
		DB_PORT=$(grep db.port $ORDS_CONF_DIR/databases/default/pool.xml|cut -d">" -f2|cut -d"<" -f1)
		DB_NAME=$(grep db.servicename $ORDS_CONF_DIR/databases/default/pool.xml|cut -d">" -f2|cut -d"<" -f1)
		printf "%s%s\n" "INFO : " "Starting the ORDS services with the following database details:"
		printf "%s%s\n" "INFO : " "  ${DB_HOST}:${DB_PORT}/${DB_NAME}."
	else
		printf "%s%s\n" "INFO : " "Starting the ORDS services."
	fi
	export CERT_FILE="$ORDS_CONF_DIR/ssl/cert.crt"
	export KEY_FILE="$ORDS_CONF_DIR/ssl/key.key"
	if [ -e ${CERT_FILE} ] && [ -e ${KEY_FILE} ]
	then	
		ords --config $ORDS_CONF_DIR serve --port 8181 --apex-images $APEXI --secure --certificate ${CERT_FILE} --key  ${KEY_FILE}
	else
		ords --config $ORDS_CONF_DIR serve --port 8181 --apex-images $APEXI
	fi
}

function run_script() {
	if [ -e $ORDS_CONF_DIR/databases/default/pool.xml ]; then
		if [ -e $CONN_STRING_FILE ]; then
			testDB
			apex
			if [ "${INS_STATUS}" == "INSTALLED" ]; then 
				run_ords
			elif [ "${INS_STATUS}" == "UPGRADE" ]; then
				install_ords
				run_ords
			elif [ "${INS_STATUS}" == "FRESH" ]; then
				install_ords
				run_ords
			fi
		else
			printf "\a%s%s\n" "WARN : " "A conn_string file has not been provided, but a mounted configuration has been detected in /etc/ords/config."
			printf "\a%s%s\n" "WARN : " "The container will start with the detected configuration."
			run_ords
		fi
	else
		# No config file then validate conn_string file and apex 
		testDB
		apex
		install_ords
		run_ords
	fi
}
run_script

