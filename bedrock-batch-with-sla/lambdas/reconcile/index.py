import json
import logging
import os
import sys
from datetime import datetime, timezone
import boto3

# Add parent directory to path for shared modules
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from common.boto_config import RETRY_CONFIG

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3', config=RETRY_CONFIG)

OUTPUT_BUCKET_NAME = os.environ['OUTPUT_BUCKET_NAME']


def handler(event, context):
    """
    Reads batch output manifest and partial results, identifies unprocessed records.
    Writes unprocessed.jsonl to S3 for on-demand fallback.
    """
    try:
        logger.info(json.dumps({'event': 'reconcile_invoked', 'input': event}))

        job_id = event['jobId']
        input_uri = event['inputUri']
        output_uri = event['outputUri']

        # Parse S3 URIs
        input_bucket, input_key = parse_s3_uri(input_uri)
        output_bucket, output_prefix = parse_s3_uri(output_uri)

        # Read input records
        input_records = read_jsonl_from_s3(input_bucket, input_key)
        input_record_ids = {rec['recordId'] for rec in input_records}

        logger.info(json.dumps({
            'event': 'input_loaded',
            'total_records': len(input_record_ids)
        }))

        # Read batch output manifest
        manifest_key = f"{output_prefix.rstrip('/')}/manifest.json.out"
        try:
            manifest = read_json_from_s3(output_bucket, manifest_key)
            processed_count = manifest.get('successCount', 0) + manifest.get('errorCount', 0)

            logger.info(json.dumps({
                'event': 'manifest_loaded',
                'processed_count': processed_count,
                'success': manifest.get('successCount', 0),
                'errors': manifest.get('errorCount', 0)
            }))
        except Exception as e:
            logger.warning(json.dumps({
                'event': 'manifest_not_found',
                'error': str(e)
            }))
            processed_count = 0
            manifest = {}

        # Read batch output to identify processed recordIds
        processed_record_ids = set()
        if processed_count > 0:
            try:
                output_prefix_clean = output_prefix.rstrip('/')
                paginator = s3.get_paginator('list_objects_v2')
                for page in paginator.paginate(Bucket=output_bucket, Prefix=output_prefix_clean):
                    for obj in page.get('Contents', []):
                        key = obj['Key']
                        if key.endswith('.jsonl.out'):
                            output_records = read_jsonl_from_s3(output_bucket, key)
                            for rec in output_records:
                                if 'recordId' in rec:
                                    processed_record_ids.add(rec['recordId'])

                logger.info(json.dumps({
                    'event': 'output_loaded',
                    'processed_records': len(processed_record_ids)
                }))
            except Exception as e:
                logger.error(json.dumps({
                    'event': 'output_read_error',
                    'error': str(e)
                }))

        # Identify unprocessed records
        unprocessed_record_ids = input_record_ids - processed_record_ids
        unprocessed_records = [rec for rec in input_records if rec['recordId'] in unprocessed_record_ids]

        logger.info(json.dumps({
            'event': 'reconciliation_complete',
            'total_input': len(input_record_ids),
            'processed': len(processed_record_ids),
            'unprocessed': len(unprocessed_records)
        }))

        # Write unprocessed records to S3
        unprocessed_key = f"unprocessed/{job_id}/unprocessed.jsonl"
        if unprocessed_records:
            write_jsonl_to_s3(OUTPUT_BUCKET_NAME, unprocessed_key, unprocessed_records)

        return {
            'statusCode': 200,
            'unprocessedKey': unprocessed_key,
            'unprocessedCount': len(unprocessed_records),
            'processedCount': len(processed_record_ids)
        }

    except Exception as e:
        logger.error(json.dumps({
            'event': 'reconcile_error',
            'error': str(e),
            'error_type': type(e).__name__
        }))
        raise


def parse_s3_uri(uri):
    """Parse s3://bucket/key into bucket and key."""
    parts = uri.replace('s3://', '').split('/', 1)
    return parts[0], parts[1] if len(parts) > 1 else ''


def read_json_from_s3(bucket, key):
    """Read JSON file from S3."""
    response = s3.get_object(Bucket=bucket, Key=key)
    return json.loads(response['Body'].read().decode('utf-8'))


def read_jsonl_from_s3(bucket, key):
    """Read JSONL file from S3."""
    response = s3.get_object(Bucket=bucket, Key=key)
    content = response['Body'].read().decode('utf-8')
    return [json.loads(line) for line in content.strip().split('\n') if line]


def write_jsonl_to_s3(bucket, key, records):
    """Write JSONL file to S3."""
    content = '\n'.join(json.dumps(rec) for rec in records)
    s3.put_object(Bucket=bucket, Key=key, Body=content.encode('utf-8'))
