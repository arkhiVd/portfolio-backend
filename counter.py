import json
import boto3
import os
import hmac
import hashlib
import base64
from decimal import Decimal

# Helper class to convert a DynamoDB item to JSON.
# This handles the Decimal type that boto3 returns.
class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return int(obj)
        return super(DecimalEncoder, self).default(obj)

# Your existing function, unchanged
def pseudonymize_ip(ip: str, secret: str) -> str:
    TRUNCATE_BYTES = 12
    mac = hmac.new(secret.encode(), ip.encode(), hashlib.sha256).digest()
    short = mac[:TRUNCATE_BYTES]
    b64 = base64.urlsafe_b64encode(short).rstrip(b'=').decode('ascii')
    return f"IP#{b64}"

def lambda_handler(event, context):
    # It's good practice to initialize clients outside the try block
    dynamodb = boto3.resource('dynamodb')
    table_name = os.environ['table_name']
    ip_hash_secret = os.environ.get('ip_hash_secret', '') # Use .get for safety
    table = dynamodb.Table(table_name)
    
    COUNTER_ID = 'portfolio_counter'
    CORS_HEADERS = {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token"
    }

    try:
        # Get visitor IP from the API Gateway event
        ip_address = event['requestContext']['identity']['sourceIp']
        visitor_id = pseudonymize_ip(ip_address, ip_hash_secret)
        
        # Check if this visitor has been seen before
        response = table.get_item(Key={'ID': visitor_id})

        # If the visitor is new, record them and increment the main counter
        if 'Item' not in response:
            table.put_item(Item={'ID': visitor_id})
            
            # Atomically increment the counter and get the new value back in one call
            update_response = table.update_item(
                Key={'ID': COUNTER_ID},
                UpdateExpression="SET visitor_count = if_not_exists(visitor_count, :start) + :inc",
                ExpressionAttributeValues={
                    ':inc': 1,
                    ':start': 0
                },
                ReturnValues="UPDATED_NEW" # Ask DynamoDB to return the new value
            )
            visitor_count = update_response['Attributes']['visitor_count']

        # If the visitor is not new, just get the current count without incrementing
        else:
            count_response = table.get_item(Key={'ID': COUNTER_ID})
            item = count_response.get('Item', {})
            visitor_count = item.get('visitor_count', 0)

        return {
            'statusCode': 200,
            'headers': CORS_HEADERS,
            'body': json.dumps({'count': visitor_count}, cls=DecimalEncoder)
        }

    except KeyError as e:
        # Add more detailed logging
        print(f"ERROR: A KeyError occurred. Missing key: {e}. Event received: {json.dumps(event)}")
        return {
            'statusCode': 400, # Bad Request is more appropriate for missing keys in event
            'headers': CORS_HEADERS,
            'body': json.dumps({'error': 'Bad request format'})
        }
    except Exception as e:
        print(f"ERROR: An unexpected error occurred: {e}")
        return {
            'statusCode': 500,
            'headers': CORS_HEADERS,
            'body': json.dumps({'error': 'An internal server error occurred'})
        }