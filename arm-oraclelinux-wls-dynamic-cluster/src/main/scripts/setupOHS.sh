#!/bin/bash

#Function to output message to StdErr
function echo_stderr ()
{
    echo "$@" >&2
}

#Function to display usage message
function usage()
{
    echo_stderr "./setupOHS.sh <ohs domain name> <ohs component name> <ohs nodemanager user> <ohs nodemanager password> <ohs http port> <ohs https port> <adminRestMgmtURL> <wlsUsername> <wlsPassword> <ohsSSLKeystoreData> <ohsSSLKeystorePassword> <oracle vault password> <keyType>"
}

# Create user "oracle", used for instalation and setup
function addOracleGroupAndUser()
{
    #add oracle group and user
    echo "Adding oracle user and group..."
    groupname="oracle"
    username="oracle"
    user_home_dir="/u01/oracle"
    USER_GROUP=${groupname}
    sudo groupadd $groupname
    sudo useradd -d ${user_home_dir} -g $groupname $username
}

# Cleaning all installer files 
function cleanup()
{
    echo "Cleaning up temporary files..."
    rm -f $BASE_DIR/setupOHS.sh
    rm -f $OHS_PATH/ohs-domain.py
    echo "Cleanup completed."
}

# Verifies whether user inputs are available
function validateInput()
{
    if [ -z "$OHS_DOMAIN_NAME" ]
    then
       echo_stderr "OHS domain name is required. "
       exit 1
    fi	
    
    if [ -z "$OHS_COMPONENT_NAME" ]
    then
       echo_stderr "OHS domain name is required. "
       exit 1
    fi	
    
    if [[ -z "$OHS_NM_USER" || -z "$OHS_NM_PSWD" ]]
    then
       echo_stderr "OHS nodemanager username and password is required. "
       exit 1
    fi	
    
    if [[ -z "$OHS_HTTP_PORT" || -z "$OHS_HTTPS_PORT" ]]
    then
       echo_stderr "OHS http port and OHS https port required."
       exit 1
    fi	
    
    if [ -z "$WLS_REST_URL" ] 
    then
       echo_stderr "WebLogic REST management url is required."
       exit 1
    fi
    
    if [ -z "${OHS_KEY_STORE_DATA}" ] || [ -z "${OHS_KEY_STORE_PASSPHRASE}" ]
    then
       echo_stderr "One of the required values for enabling Custom SSL (ohsKeyStoreData,ohsKeyStorePassPhrase) is not provided"
    fi
    
    if [ -z "$ORACLE_VAULT_PASSWORD" ]
    then
       echo_stderr "Oracle vault password is required to add custom ssl to OHS server"
    fi
    
    if [ -z "${WLS_USER}" ] || [ -z "${WLS_PASSWORD}" ]
    then
       echo_stderr "Either weblogic username or weblogic password is required"
    fi
    
    if [ -z "$OHS_KEY_TYPE" ] 
    then
       echo_stderr "Provide KeyType either JKS or PKCS12"
    fi    
}

# Setup Domain path
function setupDomainPath()
{
    #create custom directory for setting up wls and jdk
    sudo mkdir -p $DOMAIN_PATH
    sudo chown -R $username:$groupname $DOMAIN_PATH 
}

# Create .py file to setup OHS domain
function createDomainConfigFile()
{
    echo "creating OHS domain configuration file ..."
    cat <<EOF >$OHS_PATH/ohs-domain.py
import os, sys
setTopologyProfile('Compact')
selectTemplate('Oracle HTTP Server (Standalone)')
loadTemplates()
showTemplates()
cd('/')
create("${OHS_COMPONENT_NAME}", 'SystemComponent')
cd('SystemComponent/' + '${OHS_COMPONENT_NAME}')
set('ComponentType','OHS')
cd('/')
cd('OHS/' + '${OHS_COMPONENT_NAME}')
set('ListenAddress','')
set('ListenPort', '${OHS_HTTP_PORT}')
set('SSLListenPort', '${OHS_HTTPS_PORT}')
cd('/')
create('sc', 'SecurityConfiguration')
cd('SecurityConfiguration/sc')
set('NodeManagerUsername', "${OHS_NM_USER}")
set('NodeManagerPasswordEncrypted', "${OHS_NM_PSWD}")
setOption('NodeManagerType','PerDomainNodeManager')
setOption('OverwriteDomain', 'true')
writeDomain("${OHS_DOMAIN_PATH}")
dumpStack()
closeTemplate()
exit()

EOF
}

#Configuring OHS standalone domain
function setupOHSDomain()
{
    createDomainConfigFile
    sudo chown -R $username:$groupname $OHS_PATH/ohs-domain.py
    echo "Setting up OHS standalone domain at ${OHS_DOMAIN_PATH}"
    runuser -l oracle -c  "${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/common/bin/wlst.sh $OHS_PATH/ohs-domain.py"
    if [[ $?==0 ]]; 
    then
        echo "OHS standalone domain is configured successfully"
    else
        echo_stderr "OHS standalone domain is configuration failed"
        exit 1
    fi	
}

# Create OHS silent installation templates
function createOHSTemplates()
{
    sudo cp $BASE_DIR/$OHS_FILE_NAME $OHS_PATH/$OHS_FILE_NAME
    echo "unzipping $OHS_FILE_NAME"
    sudo unzip -o $OHS_PATH/$OHS_FILE_NAME -d $OHS_PATH
    export SILENT_FILES_DIR=$OHS_PATH/silent-template
    sudo mkdir -p $SILENT_FILES_DIR
    sudo rm -rf $OHS_PATH/silent-template/*
    mkdir -p $INSTALL_PATH
    create_oraInstlocTemplate
    create_oraResponseTemplate
    sudo chown -R $username:$groupname $OHS_PATH
    sudo chown -R $username:$groupname $INSTALL_PATH
}

# Create OHS nodemanager as service
function create_nodemanager_service()
{
    echo "Setting CrashRecoveryEnabled true at $DOMAIN_PATH/$OHS_DOMAIN_NAME/nodemanager/nodemanager.properties"
    sed -i.bak -e 's/CrashRecoveryEnabled=false/CrashRecoveryEnabled=true/g'  $DOMAIN_PATH/$OHS_DOMAIN_NAME/nodemanager/nodemanager.properties
    if [ $? != 0 ];
    then
        echo "Warning : Failed in setting option CrashRecoveryEnabled=true. Continuing without the option."
        mv $DOMAIN_PATH/nodemanager/nodemanager.properties.bak $DOMAIN_PATH/$OHS_DOMAIN_NAME/nodemanager/nodemanager.properties
    fi
    sudo chown -R $username:$groupname $DOMAIN_PATH/$OHS_DOMAIN_NAME/nodemanager/nodemanager.properties*
    echo "Creating NodeManager service"
    cat <<EOF >/etc/systemd/system/ohs_nodemanager.service
    [Unit]
    Description=OHS nodemanager service
    After=network-online.target
    Wants=network-online.target
    [Service]
    Type=simple
    WorkingDirectory="$DOMAIN_PATH/$OHS_DOMAIN_NAME"
    ExecStart="$DOMAIN_PATH/$OHS_DOMAIN_NAME/bin/startNodeManager.sh"
    ExecStop="$DOMAIN_PATH/$OHS_DOMAIN_NAME/bin/stopNodeManager.sh"
    User=oracle
    Group=oracle
    KillMode=process
    LimitNOFILE=65535
    Restart=always
    RestartSec=3
    [Install]
    WantedBy=multi-user.target
EOF

}

# Start the nodemanager service
function enabledAndStartNodeManagerService()
{
    sudo systemctl enable ohs_nodemanager
    sudo systemctl daemon-reload
    attempt=1
    while [[ $attempt -lt 6 ]]
    do
        echo "Starting nodemanager service attempt $attempt"
        sudo systemctl start ohs_nodemanager
        sleep 1m
        attempt=`expr $attempt + 1`
        sudo systemctl status ohs_nodemanager | grep "active (running)"
        if [[ $? == 0 ]];
  	then
            echo "ohs_nodemanager service started successfully"
            break
        fi
        sleep 3m
    done
}

#Create Start component script
function createStartComponent()
{
    cat <<EOF > $OHS_DOMAIN_PATH/startComponent.py 
import os, sys
nmConnect(username='${OHS_NM_USER}',password='${OHS_NM_PSWD}',domainName='${OHS_DOMAIN_NAME}')
status=nmServerStatus(serverName='${OHS_COMPONENT_NAME}',serverType='OHS')
if status != "RUNNING":
  nmStart(serverName='${OHS_COMPONENT_NAME}',serverType='OHS')
  nmServerStatus(serverName='${OHS_COMPONENT_NAME}',serverType='OHS')
else:
  print 'OHS component ${OHS_COMPONENT_NAME} is already running'
EOF

    sudo chown -R $username:$groupname $OHS_DOMAIN_PATH/startComponent.py
}

#Create Stop component script
function createStopComponent()
{
    cat <<EOF > $OHS_DOMAIN_PATH/stopComponent.py 
import os, sys
nmConnect(username='${OHS_NM_USER}',password='${OHS_NM_PSWD}',domainName='${OHS_DOMAIN_NAME}')
status=nmServerStatus(serverName='${OHS_COMPONENT_NAME}',serverType='OHS')
if status != "SHUTDOWN":
  nmKill(serverName='$OHS_COMPONENT_NAME',serverType='OHS')
  nmServerStatus(serverName='$OHS_COMPONENT_NAME',serverType='OHS')
else:
  print 'OHS component ${OHS_COMPONENT_NAME} is already SHUTDOWN'
EOF

    sudo chown -R $username:$groupname $OHS_DOMAIN_PATH/stopComponent.py

}

# Create OHS component as service
function createComponentService()
{
    echo "Creating ohs component service"
    cat <<EOF >/etc/systemd/system/ohs_component.service
    [Unit]
    Description=OHS Component service
    After=ohs_nodemanager.service
    Wants=ohs_nodemanager.service
	
    [Service]
    Type=oneshot
    RemainAfterExit=true
    WorkingDirectory="$DOMAIN_PATH/$OHS_DOMAIN_NAME"
    ExecStart=${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/common/bin/wlst.sh $OHS_DOMAIN_PATH/startComponent.py
    ExecStop=${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/common/bin/wlst.sh $OHS_DOMAIN_PATH/stopComponent.py
    User=oracle
    Group=oracle
    KillMode=process
    LimitNOFILE=65535
[Install]
WantedBy=multi-user.target

EOF

}

# Start the OHS component service
function enableAndStartOHSServerService()
{
    sudo systemctl enable ohs_component
    sudo systemctl daemon-reload
    echo "Starting ohs component service"
    attempt=1
    while [[ $attempt -lt 6 ]]
    do
        echo "Starting ohs component service attempt $attempt"
  	sudo systemctl start ohs_component
  	sleep 1m
  	attempt=`expr $attempt + 1`
  	sudo systemctl status ohs_component | grep active
  	if [[ $? == 0 ]];
  	then
  	    echo "ohs_component service started successfully"
  	    break
  	fi
  	sleep 3m
  done
}

# Query the WLS and form WLS cluster address
function getWLSClusterAddress()
{
    restArgs=" -v --user ${WLS_USER}:${WLS_PASSWORD} -H X-Requested-By:MyClient -H Accept:application/json -H Content-Type:application/json"
    echo $restArgs
    echo curl $restArgs -X GET ${WLS_REST_URL}/domainRuntime/serverRuntimes?fields=defaultURL > out
    curl $restArgs -X GET ${WLS_REST_URL}/domainRuntime/serverRuntimes?fields=defaultURL > out
    if [[ $? != 0 ]];
    then
        echo_stderr "REST query failed for servers"
        exit 1
    fi
    # Default admin URL is "defaultURL": "t3:\/\/10.0.0.6:7001" which is not required as part of cluster address
    msString=` cat out | grep defaultURL | grep -v "7001" | cut -f3 -d"/" `
    wlsClusterAddress=`echo $msString | sed 's/\" /,/g'`
    export WLS_CLUSTER_ADDRESS=${wlsClusterAddress::-1}
  
    # Test whether servers are reachable
    testClusterServers=$(echo ${WLS_CLUSTER_ADDRESS} | tr "," "\n")
    for server in $testClusterServers
    do
        echo curl http://${server}/weblogic/ready
        curl http://${server}/weblogic/ready
        if [[ $? == 0 ]];
        then
            echo "${server} is reachable"
        else
            echo_stderr "Failed to get cluster address properly. Cluster address received: ${wlsClusterAddress}"
            exit 1
        fi
    done
    rm -f out
}

# Create/update mod_wl_ohs configuration file based on WebLogic Cluster address
function create_mod_wl_ohs_conf()
{
    getWLSClusterAddress
  
    echo "Creating backup file for existing mod_wl_ohs.conf file"
    runuser -l oracle -c  "mv $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/mod_wl_ohs.conf $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/mod_wl_ohs.conf.bkp"
    runuser -l oracle -c  "mv $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/$OHS_COMPONENT_NAME/mod_wl_ohs.conf $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/$OHS_COMPONENT_NAME/mod_wl_ohs.conf.bkp"
  
    echo "Creating mod_wl_ohs.conf file as per ${WLS_CLUSTER_ADDRESS}"	
    cat <<EOF > $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/mod_wl_ohs.conf
    LoadModule weblogic_module   "${INSTALL_PATH}/oracle/middleware/oracle_home/ohs/modules/mod_wl_ohs.so"
    <IfModule weblogic_module>
      WLIOTimeoutSecs 900
      KeepAliveSecs 290
      FileCaching ON
      WLSocketTimeoutSecs 15
      DynamicServerList ON
      WLProxySSL ON
      WebLogicCluster ${WLS_CLUSTER_ADDRESS}
    </IfModule>
    <Location / >
      SetHandler weblogic-handler
      DynamicServerList ON
      WLProxySSL ON
      WebLogicCluster  ${WLS_CLUSTER_ADDRESS}
    </Location>
 
EOF
 
    sudo chown -R $username:$groupname $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/mod_wl_ohs.conf
    runuser -l oracle -c  "cp $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/mod_wl_ohs.conf $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/$OHS_COMPONENT_NAME/."
}

# Update the network rules so that OHS_HTTP_PORT and OHS_HTTPS_PORT is accessible
function updateNetworkRules()
{
    # for Oracle Linux 7.3, 7.4, iptable is not running.
    if [ -z `command -v firewall-cmd` ]; then
       return 0
    fi
    sudo firewall-cmd --zone=public --add-port=$OHS_HTTP_PORT/tcp
    sudo firewall-cmd --zone=public --add-port=$OHS_HTTPS_PORT/tcp
    sudo firewall-cmd --runtime-to-permanent
    sudo systemctl restart firewalld
    sleep 30s
}

# Oracle Vault needs to be created to add JKS keystore or PKCS12 certificate for OHS
function createOracleVault()
{
    runuser -l oracle -c "mkdir -p ${OHS_VAULT_PATH}"
    runuser -l oracle -c  "${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/bin/orapki wallet create -wallet ${OHS_VAULT_PATH} -pwd ${ORACLE_VAULT_PASSWORD} -auto_login"
    if [[ $? == 0 ]]; 
    then
        echo "Successfully oracle vault is created"
    else
        echo_stderr "Failed to create oracle vault"
        exit 1
    fi	
    ls -lt ${OHS_VAULT_PATH}
}

# Add provided certificates to Oracle vault created
function addCertficateToOracleVault()
{
    ohsKeyStoreData=$(echo "$OHS_KEY_STORE_DATA" | base64 --decode)
    ohsKeyStorePassPhrase=$(echo "$OHS_KEY_STORE_PASSPHRASE" | base64 --decode)

    case "${OHS_KEY_TYPE}" in
      "JKS")
          echo "$ohsKeyStoreData" | base64 --decode > ${OHS_VAULT_PATH}/ohsKeystore.jks
          sudo chown -R $username:$groupname ${OHS_VAULT_PATH}/ohsKeystore.jks
          # Validate JKS file
          KEY_TYPE=`keytool -list -v -keystore ${OHS_VAULT_PATH}/ohsKeystore.jks -storepass ${ohsKeyStorePassPhrase} | grep 'Keystore type:'`
          if [[ $KEY_TYPE == *"jks"* ]]; then
              runuser -l oracle -c  "${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/bin/orapki wallet  jks_to_pkcs12  -wallet ${OHS_VAULT_PATH}  -pwd ${ORACLE_VAULT_PASSWORD} -keystore ${OHS_VAULT_PATH}/ohsKeystore.jks -jkspwd ${ohsKeyStorePassPhrase}"
              if [[ $? == 0 ]]; then
                 echo "Successfully added JKS keystore to Oracle Wallet"
              else
                 echo_stderr "Adding JKS keystore to Oracle Wallet failed"
              fi
          else
              echo_stderr "Not a valid JKS keystore file"
              exit 1
          fi
          ;;
  	
     "PKCS12")  	
          echo "$ohsKeyStoreData" | base64 --decode > ${OHS_VAULT_PATH}/ohsCert.p12
          sudo chown -R $username:$groupname ${OHS_VAULT_PATH}/ohsCert.p12
          runuser -l oracle -c "${INSTALL_PATH}/oracle/middleware/oracle_home/oracle_common/bin/orapki wallet import_pkcs12 -wallet ${OHS_VAULT_PATH} -pwd ${ORACLE_VAULT_PASSWORD} -pkcs12file ${OHS_VAULT_PATH}/ohsCert.p12  -pkcs12pwd ${ohsKeyStorePassPhrase}"
          if [[ $? == 0 ]]; then
              echo "Successfully added certificate to Oracle Wallet"
          else
              echo_stderr "Unable to add PKCS12 certificate to Oracle Wallet"
              exit 1
          fi
     	  ;;
  esac
}

# Update ssl.conf file for SSL access and vault path
function updateSSLConfFile()
{
    echo "Updating ssl.conf file for oracle vaulet"
    runuser -l oracle -c  "cp $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/ssl.conf $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/ssl.conf.bkup"
    runuser -l oracle -c  "cp $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/$OHS_COMPONENT_NAME/ssl.conf $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/$OHS_COMPONENT_NAME/ssl.conf.bkup"
    runuser -l oracle -c  "sed -i 's|SSLWallet.*|SSLWallet \"${OHS_VAULT_PATH}\"|g' $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/instances/$OHS_COMPONENT_NAME/ssl.conf"
    runuser -l oracle -c  "sed -i 's|SSLWallet.*|SSLWallet \"${OHS_VAULT_PATH}\"|g' $OHS_DOMAIN_PATH/config/fmwconfig/components/OHS/$OHS_COMPONENT_NAME/ssl.conf"
}

#Check whether service is started
function verifyService()
{
    serviceName=$1
    sudo systemctl status $serviceName | grep "active"     
    if [[ $? != 0 ]]; 
    then
        echo "$serviceName is not in active state"
        exit 1
    fi
    echo $serviceName is active and running
}



# Execution starts here

CURR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export BASE_DIR="$(readlink -f ${CURR_DIR})"

export OHS_DOMAIN_NAME=$1
export OHS_COMPONENT_NAME=$2
export OHS_NM_USER=$3
export OHS_NM_PSWD=$4
export OHS_HTTP_PORT=$5
export OHS_HTTPS_PORT=$6
export WLS_REST_URL=$7
export WLS_USER=$8
export WLS_PASSWORD=$9
export OHS_KEY_STORE_DATA=${10}
export OHS_KEY_STORE_PASSPHRASE=${11} 
export ORACLE_VAULT_PASSWORD=${12}
export OHS_KEY_TYPE=${13}
export JDK_PATH="/u01/app/jdk"
export JDK_VERSION="jdk1.8.0_271"
export JAVA_HOME=$JDK_PATH/$JDK_VERSION
export PATH=$JAVA_HOME/bin:$PATH
export OHS_PATH="/u01/app/ohs"
export DOMAIN_PATH="/u01/domains"
export INSTALL_PATH="$OHS_PATH/install"
export OHS_DOMAIN_PATH=${DOMAIN_PATH}/${OHS_DOMAIN_NAME}
export OHS_VAULT_PATH="${DOMAIN_PATH}/ohsvault"
export  groupname="oracle"
export  username="oracle"


validateInput
setupDomainPath
setupOHSDomain
createStartComponent
createStopComponent
create_nodemanager_service
createComponentService
create_mod_wl_ohs_conf
createOracleVault
addCertficateToOracleVault
updateSSLConfFile
updateNetworkRules
enabledAndStartNodeManagerService
verifyService "ohs_nodemanager"
enableAndStartOHSServerService
verifyService "ohs_component"
cleanup
