# This is a sample python code that uses the EC2 bastion with pre-installed socat tunnel as shown in Terraform guide in this repo
# The code establishes ssm connection with pre-installed ssm plugin for aws cli, opens the session, sends the SQL query to Postgres DB, and closes the session.

import boto3
import json
import psycopg2
import time, signal
import subprocess, os, sys

aws_profile = 'default'
environments = {
   "demo":  {"bastion" : "i-04efd4761112324f9", "region" : "us-east-2"}
}

for environment, properties in environments.items():

    # the sample query to be executed
    SQL = f"""CREATE TABLE test(title VARCHAR NOT NULL, date TIMESTAMP NOT NULL DEFAULT Now());
INSERT INTO test(title) VALUES ('Hello');"""

    try:
        ssmClient = boto3.client('ssm', region_name=properties["region"])
        # start ssm session (fort-forwarding tunnel)
        ssmResponse = ssmClient.start_session(
            Target=properties["bastion"],
            DocumentName='AWS-StartPortForwardingSession',
            Parameters={
                'portNumber': [
                    '5432',
                ],
                'localPortNumber': [
                    '5432',
                ]
            }
        )
        # open the session with session manager plugin
        cmd = [
            '/usr/local/bin/session-manager-plugin',
            json.dumps(ssmResponse),
            properties["region"],  # client region
            'StartSession',
            aws_profile,  # profile name from aws credentials/config files
            json.dumps(dict(Target=properties["bastion"])),
            f'https://ssm.{properties["region"]}.amazonaws.com',  # endpoint for ssm service
        ]
        p = subprocess.Popen(cmd, preexec_fn=os.setsid)
        time.sleep(4)

        # execute the query
        try:
            conn = psycopg2.connect(
                host='localhost',
                database='postgres',
                user='postgres',
                password='postgres',
            )
            cursor = conn.cursor()
            cursor.execute(SQL)
            conn.commit()
            cursor.close()
            conn.close()
            print(f"Executed SQL query on {environment}:\n {SQL}" )
        except:
            print("SQL execution error")

        # close ssm session
        time.sleep(2)
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        ssmClient.terminate_session(SessionId=ssmResponse['SessionId'])
    except:
        print("Cannot manage Systems manager session")
        sys.exit(1)
