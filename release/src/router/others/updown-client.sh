#!/bin/sh

# Paul: adding comments to make this script a bit more maintainable
# this script is compatible with 384_17 base only.  384_19 has undergone HUGE
# refactoring, many things here are no longer applicable.

instance=$(echo "$dev" | sed "s/tun1//")

#used by openvpn_config.c write_ovpn_dns() write_ovpn_dnsmasq_config() [libvpn]
openvpnrootdir="/etc/openvpn"
openvpndnsdir="$openvpnrootdir/dns"
conffile="$openvpndnsdir/client${instance}.conf"
resolvfile="$openvpndnsdir/client${instance}.resolv"

#used by openvpn.c start/stop_ovpn_client() [rc]
dnsscript="$openvpnrootdir/fw/client${instance}-dns.sh"
qosscript="$openvpnrootdir/fw/client${instance}-qos.sh"

#local vars
fileexists=
serverips=
searchdomains=

### local helper functions
create_client_list(){
	server=$1
	VPN_IP_LIST="$(nvram get vpn_client${instance}_clientlist)"
	for n in 1 2 3 4 5; do
		VPN_IP_LIST="${VPN_IP_LIST}$(nvram get vpn_client${instance}_clientlist${n})"
	done
	OLDIFS=$IFS
	IFS="<"

	for ENTRY in $VPN_IP_LIST
	do
		if [ -z "$ENTRY" ]
		then
			continue
		fi

		VPN_IP=$(echo "$ENTRY" | cut -d ">" -f 2)
		if [ -n "$VPN_IP" ]
		then
			TARGET_ROUTE=$(echo "$ENTRY" | cut -d ">" -f 4)
			if [ "$TARGET_ROUTE" = "VPN" ]
			then
				echo /usr/sbin/iptables -t nat -A DNSVPN${instance} -s $VPN_IP -j DNAT --to-destination $server >> $dnsscript
				/usr/bin/logger -t "openvpn-updown" "Forcing $VPN_IP to use DNS server $server"
			else
				echo /usr/sbin/iptables -t nat -I DNSVPN${instance} -s $VPN_IP -j RETURN >> $dnsscript
				/usr/bin/logger -t "openvpn-updown" "Excluding $VPN_IP from forced DNS routing"
			fi
		fi
	done
	IFS=$OLDIFS
}

run_script_event(){
	if [ -f /jffs/scripts/openvpn-event ]
	then
		if [ "$(nvram get jffs2_scripts)" = "0" ]
		then
			/usr/bin/logger -t "custom_script" "Found openvpn-event, but custom script execution is disabled!"
		else
			/usr/bin/logger -t "custom_script" "Running /jffs/scripts/openvpn-event (args: $*)"
			/bin/sh /jffs/scripts/openvpn-event $*
		fi
	fi
}

### Main

# client "down" event
if [ $script_type = 'down' ]
then
	/usr/sbin/iptables -t nat -D PREROUTING -p udp -m udp --dport 53 -j DNSVPN${instance}
	/usr/sbin/iptables -t nat -D PREROUTING -p tcp -m tcp --dport 53 -j DNSVPN${instance}
	/usr/sbin/iptables -t nat -F DNSVPN${instance}
	/usr/sbin/iptables -t nat -X DNSVPN${instance}

	if [ -f $qosscript ]
	then
		sed -i "s/-A/-D/g" $qosscript
		/bin/sh $qosscript
		rm $qosscript
	fi
	
	[ -f "$resolvfile" ] && rm "$resolvfile"
  	[ -f "$dnsscript" ] && rm "$dnsscript"
fi

# check for client instance, if none, exit since there are nothing to do
if [ "$instance" = "" ] || [ "$(nvram get vpn_client${instance}_adns)" -eq 0 ]
then
	run_script_event $*
	exit 0
fi

# check if conf and resolv files exist
if [ ! -d $openvpndnsdir ]; then mkdir $openvpndnsdir; fi
if [ -f $conffile ]; then rm $conffile; fileexists=1; fi
if [ -f $resolvfile ]; then rm $resolvfile; fileexists=1; fi

# client "up" event
if [ "$script_type" = "up" ]
then

	echo "#!/bin/sh" >> $dnsscript
	echo /usr/sbin/iptables -t nat -N DNSVPN${instance} >> $dnsscript

	if [ "$(nvram get vpn_client${instance}_rgw)" -ge 2 ] && [ "$(nvram get vpn_client${instance}_adns)" -eq 3 ]
	then
		setdns=0
	else
		setdns=-1
	fi

	# Extract IPs and search domains; write WINS
	for optionname in `set | grep "^foreign_option_" | sed "s/^\(.*\)=.*$/\1/g"`
	do
		option=`eval "echo \\$$optionname"`
		if echo $option | grep "dhcp-option WINS "; then echo $option | sed "s/ WINS /=44,/" >> $conffile; fi
		if echo $option | grep "dhcp-option DNS"; then serverips="$serverips $(echo $option | sed "s/dhcp-option DNS //")"; fi
		if echo $option | grep "dhcp-option DOMAIN"; then searchdomains="$searchdomains $(echo $option | sed "s/dhcp-option DOMAIN //")"; fi
	done

	# Write resolv file
	for server in $serverips
	do
		echo "server=$server" >> $resolvfile
		if [ "$setdns" -eq 0 ]
		then
			create_client_list $server
			setdns=1
		fi
		for domain in $searchdomains
		do
			echo "server=/$domain/$server" >> $resolvfile
		done
	done

	if [ "$setdns" -eq 1 ]
	then
		echo /usr/sbin/iptables -t nat -I PREROUTING -p udp -m udp --dport 53 -j DNSVPN${instance} >> $dnsscript
		echo /usr/sbin/iptables -t nat -I PREROUTING -p tcp -m tcp --dport 53 -j DNSVPN${instance} >> $dnsscript
	fi

	# change dns scripts to executable permission
	chmod a+rx $dnsscript

	# QoS
	if [ "$(nvram get vpn_client${instance}_rgw)" -ge 1 ] && [ "$(nvram get qos_enable)" -eq 1 ] && [ "$(nvram get qos_type)" -eq 1 ]
	then
		echo "#!/bin/sh" >> $qosscript
		echo /usr/sbin/iptables -t mangle -A POSTROUTING -o br0 -m mark --mark 0x40000000/0xc0000000 -j MARK --set-xmark 0x80000000/0xC0000000 >> $qosscript

		# change QoS scripts to executable permission
		chmod a+rx $qosscript
		/bin/sh $qosscript
	fi
fi

# execute post up/down scripts/services such as dnsscripts and updateresolv
if [ -f $conffile ] || [ -f $resolvfile ] || [ -n "$fileexists" ]
then
	if [ $script_type = 'up' ] ; then
		if [ -f $dnsscript ]
		then
			/bin/sh $dnsscript
		fi
		/sbin/service updateresolv
	elif [ $script_type = 'down' ]; then
		rm $dnsscript
		if [ "$(nvram get vpn_client${instance}_adns)" = 2 ]
		then
			/sbin/service restart_dnsmasq
		else
			/sbin/service updateresolv
		fi
	fi
fi

# final attempt to cleanup of folders then exit
rmdir $openvpndnsdir
rmdir $openvpnrootdir

run_script_event $*

exit 0
