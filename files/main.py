""" This script receives notifications from Terraform Cloud workspaces
    and automatically saves the latest state file from that workspace
    to a corresponding S3 bucket. """

import base64
import hashlib
import hmac
import json
import os
import boto3
from botocore.exceptions import ClientError
import requests


REGION = os.getenv("REGION", None)
S3_BUCKET = os.getenv("S3_BUCKET", None)
SALT_PATH = os.getenv("SALT_PATH", None)
TFC_TOKEN_PATH = os.getenv("TFC_TOKEN_PATH", None)
VAULT_SECRET_FILE = os.getenv("VAULT_SECRET_FILE", None)

SAVE_STATES = {'applied'}


# Initialize boto3 client at global scope for connection reuse
session = boto3.Session(region_name=REGION)
ssm = session.client('ssm')
s3 = boto3.resource('s3')


def lambda_handler(event, context):
    """ Handle the incoming requests """
    print(event)
    # first we need to authenticate the message by verifying the hash
    message = bytes(event['body'], 'utf-8')
    salt = bytes(ssm.get_parameter(Name=SALT_PATH, WithDecryption=True)[
        'Parameter']['Value'], 'utf-8')
    hash = hmac.new(salt, message, hashlib.sha512)
    if hash.hexdigest() == event['headers']['X-Tfe-Notification-Signature']:
        # HMAC verified
        if event['httpMethod'] == "POST":
            return post(event)
        return get()
    return 'Invalid HMAC'


def get():
    """ Handle a GET request """
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": "I'm here!"
    }


def post(event):
    """ Handle a POST request """
    payload = json.loads(event['body'])
    post_response = "I'm here!"

    if payload and 'run_status' in payload['notifications'][0]:
        body = payload['notifications'][0]
        if body['run_status'] in SAVE_STATES:
            print("Run status indicates save the state file.")
            if payload['workspace_name']:
                if VAULT_SECRET_FILE:
                    vault_secret_file = open(VAULT_SECRET_FILE)
                    vault_secret = json.load(vault_secret_file)
                    tfc_api_token = vault_secret['data']['token']
                else:
                    tfc_api_token = bytes(ssm.get_parameter(
                        Name=TFC_TOKEN_PATH, WithDecryption=True)['Parameter']['Value'], 'utf-8')
                    tfc_api_token = tfc_api_token.decode("utf-8")

                state_api_url = 'https://app.terraform.io/api/v2/workspaces/' + \
                    payload['workspace_id'] + '/current-state-version'

                tfc_headers = {'Authorization': 'Bearer ' + tfc_api_token,
                               'Content-Type': 'application/vnd.api+json'}

                state_api_response = requests.get(
                    state_api_url, headers=tfc_headers)

                state_response_payload = json.loads(state_api_response.text)

                archivist_url = state_response_payload['data']['attributes'][
                    'hosted-state-download-url']

                archivist_response = requests.get(archivist_url)

                encoded_state = archivist_response.text.encode('utf-8')

                state_md5 = base64.b64encode(hashlib.md5(
                    encoded_state).digest()).decode('utf-8')

                try:
                    s3_response = s3.Bucket(S3_BUCKET).put_object(
                        Key=payload['workspace_name'], Body=encoded_state, ContentMD5=state_md5)
                    print("State file saved: ", s3_response)
                except ClientError as error:
                    print(error)

    return {
        "statusCode": 200,
        "body": json.dumps(post_response)
    }
