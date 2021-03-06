#!/bin/sh


script_path=`dirname $0`
logfile=${script_path}/gen_root.log

# load setting
if [ -s ${script_path}/setting.sh ]; then
        . ${script_path}/setting.sh
else
        echo "Error: can not load gen root functions" 
        exit 1
fi

# create arpa.zone root.zone module
gen_root_arpa_file() {

#        ns_file=$script_path/app_data/ns.sh
        rootzone_file=$script_path/app_data/root.zone
        arpazone_file=$script_path/app_data/arpa.zone
        if [ -s $ns_file  ];then
                . $ns_file
        else
                echo "$ns_file is not load"
        fi
        echo '$TTL 86400' > $rootzone_file
        echo ".        $soa_ttl   IN   SOA   $soa   $admin_mail      $serial    $refresh   $retry    $expire       $negative" >> $rootzone_file
        echo "arpa.    $soa_ttl   IN   SOA   $soa   $admin_mail      $serial    $refresh   $retry    $expire       $negative" > $arpazone_file

        ns_num=`grep "^ns_servers" $ns_file | wc -l`

        for i in `seq 1 $ns_num`;do
          ns="\$ns_servers_$i"
	  ns_name=`eval echo $ns | awk '{print $1}'`
	  ns_addr=`eval echo $ns | awk '{print $2}'`

          echo ".            ${ns_ttl}                   IN         NS         $ns_name"    >>$rootzone_file
          echo "arpa.        ${root_arpa_ns_ttl}         IN         NS         $ns_name"    >>$arpazone_file
          echo "arpa.        ${root_arpa_ns_ttl}         IN         NS         $ns_name"    >>$rootzone_file
          echo "$ns_name        $aaaa_ttl                 IN         AAAA       $ns_addr"    >>$rootzone_file

        done

}

start_time=`date +%Y%m%d%H%M%S`

# check to see newer zone is available to fetch
root_soa_check () {
	local root_serial
	root_serial=`$dig @$target . soa +short 2>/dev/null | awk '{print $3}'`
	if [ $? -ne 0 ]; then
		echo "Fails to check serial of root with $target"  >> $logfile
		echo "Fails to check serial of root with $target" \
			| mail -s "Yeti DM error" ${ADMIN_MAIL} 
		return -1
	fi
	if [ -f $serialdir/root ]; then
		if [ $root_serial -gt `cat $serialdir/root` ]; then
			return 1        # new zone is available
		fi
	else
		return 1        # force to load
	fi
	return 0
}

arpa_soa_check () {
	local arpa_serial
	arpa_serial=`$dig @$target . soa +short 2>/dev/null | awk '{print $3}'`
	if [ $? -ne 0 ]; then
		echo "Fails to check serial of arpa with $target"  >> $logfile
		echo "Fails to check serial of arpa with $target" \
			| mail -s "Yeti DM error" ${ADMIN_MAIL} 
		return -1
	fi
	if [ -f $serialdir/arpa ]; then
		if [ $root_serial -gt `cat $serialdir/arpa` ]; then
			return 1        # new zone is available
		fi
	else
		return 1        # force to load
	fi
	return 0
}

zone_download0 () {
	root_soa_check
	if [ $? -eq 1 ]; then
		$dig @$target . axfr +vc > $origin_data/root.zone
	elif [ $? -eq -1 ]; then
		return -1
	fi
	new_root_serial=`grep -m 1 SOA $origin_data/root.zone | awk '{print $7}'`

	arpa_soa_check
	if [ $? -eq 1 ]; then
		$dig @$target arpa axfr +vc > $origin_data/arpa.zone
	elif [ $? -eq -1 ]; then
		return -1
	fi
	new_arpa_serial=`grep -m 1 SOA $origin_data/root.zone | awk '{print $7}'`
}

# download root, arpa files
zone_download () {
        rm -f $origin_data/root.zone
        $dig @f.root-servers.net . axfr   >  $origin_data/root.zone
        if [ $? -ne 0 ]; then
                rm -f $origin_data/root.zone

                $dig @f.root-servers.net . axfr   >  $origin_data/root.zone > /dev/null 2>&1
                if [ $? -ne 0 ]; then
                        rm -f $origin_data/root.zone
                        $dig @f.root-servers.net . axfr > $origin_data/root.zone

                        if [ $? -ne 0 ];then
                                echo "The PM download root zonefile  failed"  >> $logfile
                                echo "Error Error Error" |mail -s "The PM download root  zonefile  failed " ${ADMIN_MAIL} 
                                exit 1

                        fi
                fi
        fi

        $dig @f.root-servers.net arpa. axfr > $origin_data/arpa.zone
        if [ $? -ne 0 ]; then
                rm -f $origin_data/arpa.zone
                $dig @f.root-servers.net arpa. axfr > $origin_data/arpa.zone
                if [ $? -ne 0 ]; then
                        rm -f $origin_data/arpa.zone
                        $dig @f.root-servers.net arpa. axfr > $origin_data/arpa.zone
                        if [ $? -ne 0 ]; then
                                echo "The PM download  zonefile  failed"  >> $logfile
                                echo "Error Error Error" |mail -s "The PM download  zonefile  failed " ${ADMIN_MAIL} 
                                exit 2
                        fi
                fi
        fi

}


# update root zone
gen_root_zone () {
        root_soa_serial_tmp=`$sed -n 2p $app_data/root.zone |awk '{print $7}'`
        root_origin_soa_serial=`$sed -n 5p $origin_data/root.zone |awk '{print $7}'`

        # zone apex
        cp $app_data/root.zone $zone_data/root.zone
        $sed -i "s/${root_soa_serial_tmp}/${root_origin_soa_serial}/g" $zone_data/root.zone

        # zone cut
        egrep -v "NSEC|RRSIG|DNSKEY|SOA|^arpa.|;" $origin_data/root.zone    > $tmp_data/root.zone.no.dnssec
        egrep -v "[a-m].root-servers.net." $tmp_data/root.zone.no.dnssec  > $tmp_data/root.zone.cut

        sleep 2

        # append zone cut
        cat $tmp_data/root.zone.cut >> $zone_data/root.zone
}

# update arpa zone
gen_arpa_zone() {
        arpa_soa_serial_tmp=`$sed -n 1p $app_data/arpa.zone |awk '{print $7}'`
        arpa_origin_soa_serial=`$sed -n 5p $origin_data/arpa.zone |awk '{print $7}'`

        # zone apex
        $sed -i "s/${arpa_soa_serial_tmp}/${arpa_origin_soa_serial}/g"  $app_data/arpa.zone
        cp $app_data/arpa.zone  $zone_data/arpa.zone

        # zone cut
        egrep -v "NSEC|RRSIG|DNSKEY|SOA|;" $origin_data/arpa.zone > $tmp_data/arpa.zone.no.dnssec
        egrep -v  [a-m].root-servers.net $tmp_data/arpa.zone.no.dnssec  > $tmp_data/arpa.zone.cut
         
        # append zond cut
        cat $tmp_data/arpa.zone.cut >> $zone_data/arpa.zone
}


sign_arpa_zone () {

         $dnssecsignzone -K $arpakeydir -o arpa. -O full -S -x $zonedir/arpa.zone
          if [ $? -eq 0 ] 
             then
                 $sed '/^;/d'  $zonedir/arpa.zone.signed > ${ROOT_ZONE_PATH}/arpa.zone.signed
                  /bin/cp -f $zonedir/arpa.zone ${ROOT_ZONE_PATH}
          else
                 echo "arpa zone signed failed" >> $logfile
                 echo "Error Error Error" | mail -s "arpa zone signed failed" ${ADMIN_MAIL}
                exit 1
          fi 

}

#insert arpa_ds into root.zone
insert_arpa_ds() {
	cat ${script_path}/dsset-arpa.  >> $zonedir/root.zone
}

# sign root zone
sign_root_zone() {
        $dnssecsignzone -K $rootkeydir -o . -O full -S -x $zonedir/root.zone
        if [ $? -eq 0 ]; then 
                $sed '/^;/d'  $zonedir/root.zone.signed >  ${ROOT_ZONE_PATH}/root.zone.signed
                /bin/cp -f $zonedir/root.zone ${ROOT_ZONE_PATH}
        else 
                echo "root zone signed fail !!!" >> $logfile
                echo "Error Error Error" | mail -s "root zone signed fail"  ${ADMIN_MAIL}
                exit 1
        fi
}

# reload  bind
reload_bind() {
        $rndc reload
        if [  $? -eq  0 ]; then
                echo "PM named reload successful" >> $logfile
        else
                echo "Error Error Error " |mail -s "PM named reload failed " ${ADMIN_MAIL}
                exit 1
        fi
}

# sync zone file to github
update_data()  {
        cd ${ROOT_ZONE_PATH} 
        sh github.sh
        cd 
}
