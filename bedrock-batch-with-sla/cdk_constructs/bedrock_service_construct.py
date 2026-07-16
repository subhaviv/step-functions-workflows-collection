import aws_cdk.aws_iam as iam
import aws_cdk.aws_s3 as s3
from constructs import Construct


class BedrockServiceConstruct(Construct):
    def __init__(self, scope: Construct, construct_id: str,
                 input_bucket: s3.IBucket, output_bucket: s3.IBucket) -> None:
        super().__init__(scope, construct_id)

        self.service_role = iam.Role(
            self, "BedrockServiceRole",
            role_name="bedrock-batch-sla-service-role",
            assumed_by=iam.ServicePrincipal("bedrock.amazonaws.com"),
            description="Service role for Bedrock batch inference jobs",
        )

        self.service_role.add_to_policy(iam.PolicyStatement(
            effect=iam.Effect.ALLOW,
            actions=["s3:GetObject", "s3:ListBucket"],
            resources=[input_bucket.bucket_arn, f"{input_bucket.bucket_arn}/*"],
        ))

        self.service_role.add_to_policy(iam.PolicyStatement(
            effect=iam.Effect.ALLOW,
            actions=["s3:PutObject", "s3:ListBucket"],
            resources=[output_bucket.bucket_arn, f"{output_bucket.bucket_arn}/*"],
        ))

        self.service_role.add_to_policy(iam.PolicyStatement(
            effect=iam.Effect.ALLOW,
            actions=["bedrock:InvokeModel"],
            resources=["*"],
        ))

        self.service_role_arn = self.service_role.role_arn
