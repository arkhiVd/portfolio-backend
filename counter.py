import json
import boto3
import os
import hmac
import hashlib
import base64

def pseudonymize_ip(ip: str, secret: str) -> str:
    TRUNCATE_BYTES = 12
    mac = hmac.new(secret.encode(), ip.encode(), hashlib.sha256).digest()
    short = mac[:TRUNCATE_BYTES]
    b64 = base64.urlsafe_b64encode(short).rstrip(b'=').decode('ascii')
    return f"IP#{b64}"

def lambda_handler(event, context):
    try:
        dynamodb = boto3.resource('dynamodb')
        table = dynamodb.Table(os.environ['table_name'])
        ip_hash_secret = os.environ['ip_hash_secret']
        COUNTER_ID = 'portfolio_counter'
        ip_address = event['requestContext']['identity']['sourceIp']
        visitor_id = pseudonymize_ip(ip_address, ip_hash_secret)
        
        response = table.get_item(Key={'ID': visitor_id})

        if 'Item' not in response:
            table.put_item(Item={'ID': visitor_id})
            table.update_item(
                Key={'ID': COUNTER_ID},
                UpdateExpression="SET visitor_count = if_not_exists(visitor_count, :start) + :inc",
                ExpressionAttributeValues={
                    ':inc': 1,
                    ':start': 0
                }
            )
        
        final_count_response = table.get_item(Key={'ID': COUNTER_ID})
        visitor_count = int(final_count_response.get('Item', {}).get('visitor_count', 0))

        return {
            'statusCode': 200,
            'headers': {
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type"
            },
            'body': json.dumps({'count': visitor_count})
        }

    except KeyError as e:
        print(f"A KeyError occurred! The missing key is: {e}")
        return {'statusCode': 500, 'body': json.dumps({'error': 'Internal server configuration error'})}
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return {'statusCode': 500, 'body': json.dumps({'error': 'An internal error occurred'})}