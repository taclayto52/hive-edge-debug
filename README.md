# Setup

This repo is for testing bridge outages between two HiveMQ Edge servers, using a [ToxiProxy](https://github.com/Shopify/toxiproxy) container as a method for injecting network faults.

MQTT broker A -> ToxiProxy -> MQTT broker B

1. Start bridge testing environment using 
```sh
docker compose up -d
```
1. Listen to subscriptions on both broker A and B

```sh
mqtt sub -i subA -h localhost -p 1883 -t testing/this/out
```

```sh
mqtt sub -i subB -h localhost -p 1884 -t testing/this/out
```

3. Install the MQTT lib required by the Python script
```sh
pip3 install -r requirements.txt
``` 

4. Start sending a set of messages 
```sh
python3 scripts/mqtt-publish-burst.py --host localhost --port 1883 --topic "testing/this/out" --count 100000 --delay 0.0100 --message-size 50 
```
The python script accepts arguments to tune the amount of throughput:

It will send the number of messages dictated `--count` with a sleep between sends dictated by `--delay`. The message size will be set to `--message-size` in bytes. 

By default, ToxiProxy does not have any toxics enabled so it is just acting as a passive proxy. 

# Bridge persistent disconnection bug
The following steps will eventually result in a HiveMQ Edge bridge that reports as being "connected" but stops forwarding messages.

1. Setting up both subscriptions on broker A and B

```sh
mqtt sub -i subA -h localhost -p 1883 -t testing/this/out
```

```sh
mqtt sub -i subB -h localhost -p 1884 -t testing/this/out
```

2. Start sending a large load of traffic on the broker (with a decently large payload)
```sh
python3 scripts/mqtt-publish-burst.py --host localhost --port 1883 --topic "testing/this/out" --count 100000 --delay 0.0100 --message-size 3000 
```

3. Inject a `limit_data` type toxic into the ToxiProxy instance:

```
./scripts/toxiproxy-toxics.sh temporary limit 30 
```

This enables a toxic that temporarily simulates a network that closes in the middle of message being sent over the bridge. 

It may take a few attempts but eventually the bridge will get into a bad state, where the toxic has been removed and the bridge will continue to report connected but messages are no longer forwarded. 

I have only been able to resolve this by restarting the broken broker (in this case broker A). 