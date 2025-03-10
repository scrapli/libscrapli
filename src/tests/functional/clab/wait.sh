#!/bin/bash
MAX_TIME=300
INTERVAL=5
END_TIME=$((SECONDS + MAX_TIME))

while [ $SECONDS -lt $END_TIME ]; do
    sshpass -p "NokiaSrl1!" \
      ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -l admin 172.20.20.16 quit

    if [ $? -eq 0 ]; then
        exit 0
    fi

    sleep $INTERVAL
done

while [ $SECONDS -lt $END_TIME ]; do
    nc -zv 172.20.20.16 21830

    if [ $? -eq 0 ]; then
        exit 0
    fi

    sleep $INTERVAL
done

exit 1
