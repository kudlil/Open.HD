function MAIN_HOTSPOT_FUNCTION {
    echo "================== CHECK HOTSPOT (tty8) ==========================="
    
    if [ "${CAM}" == "0" ]; then

            
        echo -n "Waiting until video is running ..."

        HVIDEORXRUNNING=0
        
        while [ ${HVIDEORXRUNNING} -ne 1 ]; do
            sleep 0.5

            HVIDEORXRUNNING=`pidof $DISPLAY_PROGRAM | wc -w`

            echo -n "."
        done

        
        echo
        echo "Video running, starting hotspot processes ..."
        
        sleep 1
        
        hotspot_check_function
    else
        echo "Hotspot not enabled, running on air side"

        sleep 365d
    fi
}


function hotspot_check_function {

    #
    # Convert hostap config from DOS format to UNIX format
    #
    ionice -c 3 nice dos2unix -n /boot/apconfig.txt /tmp/apconfig.txt

    pause_while

    nice cat /root/telemetryfifo5 > /dev/pts/0 &
    /usr/local/bin/mavlink-routerd -e 127.0.0.1:14550 /dev/pts/1:115200 &

    #
    # Phone can be connected at any time, so always start hotspot programs
    # 
    # TODO: add code inside USB tethering file to check if hotspot is off and phone connected
    #

    #if [ "$ETHERNET_HOTSPOT" == "Y" ] || [ "$WIFI_HOTSPOT" != "N" ]; then
        /home/pi/wifibroadcast-scripts/UDPsplitterhelper.sh 9121 5621 ${VIDEO_UDP_PORT2} &  #Secondary video stream
        /home/pi/wifibroadcast-scripts/UDPsplitterhelper.sh 9120 5620 ${VIDEO_UDP_PORT} &  #Main video stream

        if [ "${FORWARD_STREAM}" == "rtp" ]; then
            echo "ionice -c 1 -n 4 nice -n -5 cat /root/videofifo2 | nice -n -5 gst-launch-1.0 fdsrc ! h264parse ! rtph264pay pt=96 config-interval=5 ! udpsink port=5620 host=127.0.0.1 > /dev/null 2>&1 &" > /tmp/ForwardRTPMainCamera.sh
        else
            echo "ionice -c 1 -n 4 nice -n -10 socat -b ${VIDEO_UDP_BLOCKSIZE} GOPEN:/root/videofifo2 UDP4-SENDTO:127.0.0.1:5620 &" > /tmp/ForwardRTPMainCamera.sh
        fi

        chmod +x /tmp/ForwardRTPMainCamera.sh

        /tmp/ForwardRTPMainCamera.sh &
    #fi


    #
    # Redirect telemetry to UDP splitter
    #
    nice socat -b ${TELEMETRY_UDP_BLOCKSIZE} GOPEN:/root/telemetryfifo2 UDP4-SENDTO:127.0.0.1:6610 &
    /home/pi/wifibroadcast-scripts/UDPsplitterhelper.sh 9122 6610 ${TELEMETRY_UDP_PORT} &
    

    #
    # This is pretty crude, but ensures that all telemetry protocols will be forwarded to QOpenHD
    # when running on the ground station. 
    # 
    # Normally, devices joining the hotspot will trigger forwarding like this, but when running on the
    # ground station itself that never happens so it has to be triggered manually
    #
    ( sleep 10; echo "add 127.0.0.1"  > /dev/udp/127.0.0.1/9122 ) &

    #
    # TODO: use constants for all these ports
    #
    nice /home/pi/wifibroadcast-base/rssi_forward 127.0.0.1 5003 &
    /home/pi/wifibroadcast-scripts/UDPsplitterhelper.sh 9123 5003 5003 &

    nice /home/pi/wifibroadcast-base/rssi_qgc_forward 127.0.0.1 5154 &
    /home/pi/wifibroadcast-scripts/UDPsplitterhelper.sh 9124 5154 5154 &


    #
    # Distribute remote settings messages to connected hotspot devices
    # 
    /home/pi/wifibroadcast-scripts/UDPsplitterhelper.sh 9125 5116 5115 &

    #
    # Distribute Open.HD telemetry/rssi to QOpenHD when running on the ground station
    #
    nice /home/pi/wifibroadcast-base/rssi_qgc_forward 127.0.0.1 5155 &


    #if [ "$TELEMETRY_UPLINK" == "msp" ]; then
        #cat /root/mspfifo > /dev/pts/2 &
        #ser2net
    #fi


    #
    # Setup ethernet "hotspot"
    # 
    # Basically just starts a DHCP server so that users don't need to connect to a router
    #
    if [ "$ETHERNET_HOTSPOT" == "Y" ]; then
        nice ifconfig eth0 192.168.1.1 up
        nice /usr/sbin/dnsmasq --conf-file=/etc/dnsmasqEth0.conf
    fi



    if [ "$WIFI_HOTSPOT" != "N" ]; then
        detect_hardware

        echo "Running on Pi model $MODEL with hotspot band $ABLE_BAND"

        if [ "$ABLE_BAND" != "unknown" ]; then
            echo "Setting up Hotspot..."

            if [ "$WIFI_HOTSPOT" == "auto" ] && [ "$WIFI_HOTSPOT_NIC" == "internal" ]; then	
                echo "wifihotspot auto..."

                #
                # Automatically choose a hotspot band that will not conflict with the Open.HD broadcast link
                #
                if [ "$ABLE_BAND" == "ag" ]; then
                    echo "Dual Band capable..."

                    if [ "$FREQ" -gt "3000" ]; then
                        HOTSPOT_BAND=g
                        HOTSPOT_CHANNEL=7
                    else
                         HOTSPOT_BAND=a
                        HOTSPOT_CHANNEL=36
                    fi
                else
                    echo "G Band only capable..."

                    HOTSPOT_BAND=g

                    if [ "$FREQ" -gt "3000" ]; then
                        HOTSPOT_CHANNEL=1
                    else
                        echo "Hotspot disabled, you are using a 2.4Ghz Open.HD wifi card but your ground station only supports 2.4Ghz hotspot"	
                        return 1
                    fi
                fi
            fi

            #
            # Read the hotspot configuration file and replace the band/channel according to the WiFi band checks done above here
            #
            source /tmp/apconfig.txt

            sudo sed -i -e "s/hw_mode=$hw_mode/hw_mode=$HOTSPOT_BAND/g" /tmp/apconfig.txt
            sudo sed -i -e "s/channel=$channel/channel=$HOTSPOT_CHANNEL/g" /tmp/apconfig.txt

            echo "setting up hotspot with mode $HOTSPOT_BAND on channel $HOTSPOT_CHANNEL"
            tmessage "setting up hotspot with mode $HOTSPOT_BAND on channel $HOTSPOT_CHANNEL..."

            #
            # Start a DHCP server and then configure access point management
            # 
            /usr/sbin/dnsmasq --conf-file=/etc/dnsmasqWifi.conf
            nice -n 5 hostapd -B -d /tmp/apconfig.txt
        
            # 
            # Migration for users with old config files to ensure that the hotspot power is still set 
            #
            if [ ${HOTSPOT_TXPOWER} != "" ]; then
                iw dev wifihotspot0 set txpower fixed ${HOTSPOT_TXPOWER}
            else
                iw dev wifihotspot0 set txpower fixed 100
            fi
        else
            echo "No hotspot capable hardware"
            tmessage "No hotspot capable hardware"
        fi 
        

        #
        # Allow users to configure a hotspot timeout, which means at boot the hotspot will be turned on
        # for a while allowing them to use a phone to change settings, but then it will be completely disabled
        #
        # This is a feature that most people will not need, as modern Pi hardware that supports both frequency bands
        # allows us to leave it running all the time.
        #
        if [ "$HOTSPOT_TIMEOUT" != "0" ]; then

            if [ "$ENABLE_QOPENHD" == "Y" ]; then
                qstatus "Hotspot Shutting Down in ${HOTSPOT_TIMEOUT} seconds" 3
            else
                wbc_status "Hotspot Shutting Down in ${HOTSPOT_TIMEOUT} seconds" 7 55 0 &
            fi


            sleep $HOTSPOT_TIMEOUT
            
            killall hostapd
            
            ps -ef | nice grep "wifihotspot" | nice grep -v grep | awk '{print $2}' | xargs kill -9
            
            if [ "$ENABLE_QOPENHD" == "Y" ]; then
                qstatus "Hotspot Shut Down" 3
            else
                wbc_status "Hotspot Shut Down" 7 55 0 &
            fi
        fi
    fi



}
