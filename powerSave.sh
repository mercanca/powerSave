#!/bin/bash 
# Ahmet Mercan, 29/08/2018
# Elektrik Tasarrufu icin, power on/off Betigi

PwSaveDir=/root/cron_tmp_dir
PwSaveLog=$PwSaveDir/powerSave.log
PwSaveLogLONG=$PwSaveDir/powerSaveLOG-LONG.log
PwSaveCanOff=$PwSaveDir/poweroff-can.txt
PwSaveCanOn=$PwSaveDir/poweron-can.txt
PwSaveCanNotOff=$PwSaveDir/poweron-can-idles.txt
PwSaveSTOP=$PwSaveDir/powerSave-STOP
PwSavePOD=$PwSaveDir/powerSave-PowerOnDate

if [ -f "$PwSaveSTOP" ]
then
	echo "`date` POWER SAVE STOP SETTED, EXITING!.............."  >>$PwSaveLog
	exit 0
fi


#============================================================================
# Adminlere mail atar. parametresi baslik icindeki-yazi 
#============================================================================
function mailYOLLA()
{
	echo "$2 --- $PUTTIME" |  mail -s "PROBLEM: $1" ahmet@example.com mercan@exaple.com
}


#===================================================================================
# Bir Kuyrukta Bekleyen isler icin needed makina sayisini verir.
function waitingintheQueue()
{
squeue  -t PENDING -O numnodes,reason -h -p $1 |awk 'BEGIN{count=0;} (($2 != "Licenses")&&($2 != "AssocGrpCPUMinutesLi")&&($2 != "DependencyNeverSatis")) {count+=$1;} END{print count}'

}
#===================================================================================


#===================================================================================
# Kuyruklarin Listesini, kuyruktaki makinalarin isimlerini, sayisini ve enaz acik olmasi needed sayisini verir. 
function queueList()
{
scontrol show partition  -o|tr "=" " "|awk -v minmak="$SUSPENDTIME" '{if (minmak==0) minLimit=$56/12; else minLimit=$56/8; if (minLimit<3) minLimit=3; print $2, $36, $56,int(minLimit);}'|grep -v -E 'all|mixq'
}
#===================================================================================


#===================================================================================
# Verilen Kuyruktaki Makina Listesini verir. 
function nodeList()
{
#scontrol show node  -o $1 |sort |tr '=' ' '
/uhem-bin/slurm-node-info -p $1 | awk '{sub(/f/,"z",$1);print;}'|sort|awk '{sub(/z/,"f",$1);print;}'
}
#===================================================================================

#===================================================================================
# Verilen listedeki acilmamis Makina Listesini verir. 
function serversPowerOffAlready()
{
local _inputs="$*"
if [ "$_inputs" != "" ]
then
	for nn in ${_inputs}; do /uhem-bin/slurm-node-info -n $nn; done | awk  '(($12 ~ /PwrON_State_PowerSave/)||($12 ~ /PowerSave_PwrOffState/)) {printf "%s,",$1}'
fi
}
#===================================================================================

#===================================================================================
# Verilen listedeki acilmamis Makina Listesini verir. 
function serversCouldnotPowerOn()
{
	 /uhem-bin/slurm-node-info -a | awk  '($12 ~ /PwrON_State_PowerSave/) {printf "%s,",$1}'
}
#===================================================================================



hour=`date '+%k'`
TIMENOW=`date '+%s'`
LIVETIME=`date '+%F_%T'`
SUSPENDTIME=3600;

echo "`date` POWER SAVE BEGIN ====================================" >>$PwSaveLog

tail -n 877 /var/www/html/ld50/tarihcedol.json | awk -v hour="${hour// /}" '
BEGIN{
	sum=0;count=0;sumST=0;countST=0;
	future=(hour+1)%24;
	past=(hour-1+24)%24;
} 
{
	sub(/:.*/,"",$6); 
	sub(/^0/,"",$6); 
	if ((NR<840)&&($6==past)){ 
		sumST+=$13; sumST+=$22; countST++;}; 
	if ((NR<840)&&($6==future)){
		sum+=$13; sum+=$22; count++;}
} 
END{
	if (count==0) count=1; if (sumST==0) sumST=1; 
	print int((100*sum*countST)/(sumST*count)); 
}'  >$PwSaveDir/dolort.txt
DOLORT=`cat $PwSaveDir/dolort.txt`

if [[ "$DOLORT" -gt 105 ]]
then 
	SUSPENDTIME=10800;
else 
	if [[ "$DOLORT" -lt 98 ]] 
	then
		SUSPENDTIME=0;
	else
		SUSPENDTIME=3600;
	fi
fi
echo "`date` POWER dolort%= ${DOLORT} SUSPENDTIME=  ${SUSPENDTIME}" &>>$PwSaveLog

echo -n >$PwSaveCanOff
echo -n >$PwSaveCanOn
# bu makineler düzgün açılmadığından kapatılmasınlar istiyorum.
# Not power off list
echo -e "s030\ns035\ns112" >$PwSaveCanNotOff



CAVAILABLE3="`serversCouldnotPowerOn`"
echo "`date` POWER ON PREVIOUSLY1: ${CAVAILABLE3}" &>>$PwSaveLog
CAVAILABLE2="${CAVAILABLE3%%,}"
echo "`date` POWER ON PREVIOUSLY2: ${CAVAILABLE2}" &>>$PwSaveLog
/uhem-bin/clush-ipmi $CAVAILABLE2  power on   &>>$PwSaveLogLONG
if [ "${CAVAILABLE2%%,}" != "" ]
then
	clush -w "${CAVAILABLE2%%,}"  "systemctl -q is-active okyanus.mount || systemctl restart okyanus.mount;systemctl -q is-active slurmd.service || systemctl restart slurmd.service;systemctl -q is-active slurmd.service && scontrol update NodeName=\$HOSTNAME State=UNDRAIN Reason=PwrON_State_PowerSave_${LIVETIME}" &>>$PwSaveLogLONG
fi



queueList | while read name part maktop minLimit; 
do 
	LASTPOWERON=`cat $PwSavePOD-$name.seconds`
	waiting=$(waitingintheQueue $name ); 
	IDLECOUNT=`nodeList $name | awk -v minLimit=$minLimit 'BEGIN{idleCount=0;} ($9 == "IDLE") {idleCount++;} END{print idleCount;}'`
	((needed=waiting+minLimit-1))
	((needed2=waiting+minLimit+1))
	((ELAPSED=TIMENOW-LASTPOWERON))

	if [[ "$waiting" -gt 0  ||  "$IDLECOUNT" -lt "$needed" ]]    # && ! [[ "$hour" -gt 17  &&  "$hour" -lt 22 ]]  ; 
	then 
		#WILLBEPOWERON CANDIDATES
		nodeList $name  |awk -v minLimit=$minLimit -v needed=$needed -v idleCount=$IDLECOUNT 'BEGIN{count=0;} ($12 ~ /PowerSave_PwrOffState/) {count++; if ((count+idleCount)<=needed) print $1}' >>$PwSaveCanOn
		echo $TIMENOW >$PwSavePOD-$name.seconds
		#KAPATILMAMASI GEREKENLER
		nodeList $name | awk   'BEGIN{count=0;}  ($9 ~ /IDLE/) {print $1}' >>$PwSaveCanNotOff
		echo "`date` $name $part min:$minLimit wait::$waiting need::$needed-$needed2 idl:$IDLECOUNT elapsed:$ELAPSED WILLBEPOWERON" >>$PwSaveLog
	else
		if [ "$IDLECOUNT" -gt "$needed2" ] && [ $ELAPSED -gt $SUSPENDTIME ]  # || [[ "$hour" -gt 17  &&  "$hour" -lt 22 ]]
		then 
			#WILLBEPOWEROFF CANDIDATES
			nodeList $name | awk  -v needed=$needed2   'BEGIN{count=0;}  ($9 == "IDLE") {count++; if (count>=needed) {print $1}}' >>$PwSaveCanOff
			echo "`date` $name $part min:$minLimit wait::$waiting need::$needed-$needed2 idl:$IDLECOUNT elapsed:$ELAPSED WILLBEPOWEROFF" >>$PwSaveLog
		else
			#KAPATILMAMASI GEREKENLER
			nodeList $name | awk   'BEGIN{count=0;}  ($9 ~ /IDLE/) {print $1}' >>$PwSaveCanNotOff
			echo "`date` $name $part min:$minLimit wait::$waiting need::$needed-$needed2 idl:$IDLECOUNT elapsed:$ELAPSED KEEPSTATUS" >>$PwSaveLog
		fi
	fi; 
done 


echo "`date` WILLBEPOWERON CANDIDATES: `cat $PwSaveCanOn|tr \"\n\" \" \"`" >>$PwSaveLog
echo "`date` WILLBEPOWEROFF CANDIDATES: `cat $PwSaveCanOff|tr \"\n\" \" \"`" >>$PwSaveLog

#WILLBEPOWERON
AVAILABLE2=`sort $PwSaveCanOn | uniq |tr "\n" " "`
AVAILABLE3=`sort $PwSaveCanNotOff | uniq |tr "\n" " "`
echo "`date` KAPATILMAYACAKLAR: ${AVAILABLE3}" >>$PwSaveLog
#WILLBEPOWEROFF
AVAILABLE=`sort $PwSaveCanOff | uniq |grep -v -E "^${AVAILABLE2// /$|^}\$|^${AVAILABLE3// /$|^}\$" |tr "\n" " "`


#========================================================================================================
# Ahmet Mercan, 29/08/2018
# Elektrik Tasarrufu icin, power off kismi
#========================================================================================================



	echo "`date` POWER OFF LIST:  $AVAILABLE"  >>$PwSaveLog
	if [ "${AVAILABLE// /}" != "" ]
	then
		for i in $AVAILABLE
		do
			scontrol update NodeName=$i State=DRAIN Reason="PowerSave_PwrOffState_${LIVETIME}"
		done

		for i in $AVAILABLE
		do
			clush -w  $i  "sudo /usr/sbin/shutdown -h now 2>/dev/null" &>>$PwSaveLogLONG
		done
		sleep 60 && \
		AVAILABLE="${AVAILABLE// /,}"
		for iii in 1 2 3 4 5 6
		do
			if [ "${AVAILABLE// /}" != "" ]
			then
				CAVAILABLE3=`/uhem-bin/clush-ipmi $AVAILABLE power status |awk '/\<on\>|\<On\>/{printf "%s",$1}'`
				AVAILABLE="${CAVAILABLE3//:/,}"
				CAVAILABLE3="${AVAILABLE// /}"
				if [ "${CAVAILABLE3%%,}" != "" ]
				then
					/uhem-bin/clush-ipmi ${CAVAILABLE3%%,}  power off   &>>$PwSaveLogLONG
					sleep 1
				else
					break
				fi
			else
				break
			fi
		done
		if [ "${AVAILABLE// /}" != "" ]
		then
			CAVAILABLE3=`/uhem-bin/clush-ipmi $AVAILABLE power status |awk '/\<on\>|\<On\>/{printf "%s",$1}'`
			AVAILABLE="${CAVAILABLE3//:/,}"
			CAVAILABLE3="${AVAILABLE// /}"
			if [ "${CAVAILABLE3%%,}" != "" ]
			then
				echo "`date` POWER OFF SERVERs COULD NOT POWER OFF: ${CAVAILABLE3}" &>>$PwSaveLog
				mailYOLLA "Sariyer POWERSAVE: power off PROBLEM" "`date` POWER OFF SERVERs COULD NOT POWER OFF: ${CAVAILABLE3}"
				for i in ${CAVAILABLE3//,/ }
				do
				scontrol update NodeName=$i State=DOWN Reason=COULDNOTPOWEROFF_PowerSave_${LIVETIME}		
				done
			fi
		fi
	fi
	echo "`date` POWER OFF THE END." >>$PwSaveLog
#fi

#========================================================================================================
# Ahmet Mercan, 29/08/2018
# Elektrik Tasarrufu icin, power on kismi
#========================================================================================================



echo "`date` POWER ON LIST:  $AVAILABLE2"  >>$PwSaveLog

CAVAILABLE2="${AVAILABLE2// /,}"

if [ "$AVAILABLE2" == "" ] ; then echo "`date` POWER ON THE END" &>>$PwSaveLog; exit 0; fi

echo "`date` POWER ON LIST:  $AVAILABLE2"  >>$PwSaveLogLONG
echo "${CAVAILABLE2%%,} POWER ON begins" &>>$PwSaveLogLONG

for i in $AVAILABLE2
do
	scontrol update NodeName=$i State=DRAIN Reason="PwrON_State_PowerSave_${LIVETIME}"
	/uhem-bin/clush-ipmi $i power on &>>$PwSaveLogLONG
	sleep 1
done
/uhem-bin/clush-ipmi $CAVAILABLE2  power on   &>>$PwSaveLogLONG
sleep 3
/uhem-bin/clush-ipmi $CAVAILABLE2  power on   &>>$PwSaveLogLONG

echo "`date` POWER ON SLEEP 210" &>>$PwSaveLog
sleep 210 && clush -w "${CAVAILABLE2%%,}"  "/usr/sbin/tuned-adm profile powersave" &>>$PwSaveLogLONG
clush -w "${CAVAILABLE2%%,}"  "systemctl -q is-active slurmd.service && scontrol update NodeName=\$HOSTNAME State=UNDRAIN Reason=PwrON_State_PowerSave_${LIVETIME}" &>>$PwSaveLogLONG
echo "${CAVAILABLE2%%,} loop starting" &>>$PwSaveLogLONG

for iii in 1 2 3 4 5 6 7 8 9 10
do
	CAVAILABLE3="`serversPowerOffAlready ${CAVAILABLE2%%,}`"
	echo "`date` POWER ON WAITINGFOR1: ${CAVAILABLE3}" &>>$PwSaveLog
	CAVAILABLE2="${CAVAILABLE3%%,}"
	echo "`date` POWER ON WAITINGFOR2: ${CAVAILABLE2}" &>>$PwSaveLog
	if [ "${CAVAILABLE2%%,}" != "" ]
	then
		echo "${CAVAILABLE2%%,} for loop:$iii" &>>$PwSaveLogLONG
		clush -w "${CAVAILABLE2%%,}"  "systemctl -q is-active okyanus.mount || systemctl restart okyanus.mount;systemctl -q is-active slurmd.service || systemctl restart slurmd.service;systemctl -q is-active slurmd.service && scontrol update NodeName=\$HOSTNAME State=UNDRAIN Reason=PwrON_State_PowerSave_${LIVETIME}" &>>$PwSaveLogLONG
	sleep 1
	fi
done

	CAVAILABLE3="`serversPowerOffAlready ${CAVAILABLE2%%,}`"
	CAVAILABLE2="${CAVAILABLE3%%,}"
	if [ "${CAVAILABLE2%%,}" != "" ]
	then
		echo "`date` POWER ON SERVERs CAN NOT POWER ON: ${CAVAILABLE2}" &>>$PwSaveLog
		mailYOLLA "Sariyer POWERSAVE: power on PROBLEM" "`date` POWER ON SERVERs CAN NOT POWER ON: ${CAVAILABLE2}"
		for i in ${CAVAILABLE2//,/ }
		do
		echo "`date` POWER ON SERVER CAN NOT POWER ON scontrol: ${i}" &>>$PwSaveLog
		scontrol update NodeName=$i State=DOWN Reason=COULDNOTPOWERON_PowerSave_${LIVETIME}		
		done
	fi

echo "`date` POWER ON THE END" &>>$PwSaveLog

