import os
import aws_cdk as cdk
import aws_cdk.aws_lambda as lambda_
import aws_cdk.aws_iam as iam
import aws_cdk.aws_dynamodb as dynamodb
import aws_cdk.aws_s3 as s3
from constructs import Construct

LAMBDAS_DIR = os.path.join(os.path.dirname(__file__), "../lambdas")


class LambdaComputeConstruct(Construct):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        jobs_table: dynamodb.Table,
        input_bucket: s3.Bucket,
        output_bucket: s3.Bucket,
        bedrock_service_role_arn: str,
        model_id: str,
        timeout_duration_hours: int,
        batch_cutoff_seconds: int,
        max_concurrency: int,
        stuck_threshold_minutes: int,
    ) -> None:
        super().__init__(scope, construct_id)

        self.execution_role = iam.Role(
            self, "LambdaExecutionRole",
            role_name="bedrock-batch-sla-lambda-execution",
            assumed_by=iam.ServicePrincipal("lambda.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AWSLambdaBasicExecutionRole"),
            ],
        )

        self.execution_role.add_to_policy(iam.PolicyStatement(
            effect=iam.Effect.ALLOW,
            actions=[
                "bedrock:CreateModelInvocationJob",
                "bedrock:GetModelInvocationJob",
                "bedrock:ListModelInvocationJobs",
                "bedrock:StopModelInvocationJob",
                "bedrock:InvokeModel",
            ],
            resources=["*"],
        ))

        self.execution_role.add_to_policy(iam.PolicyStatement(
            effect=iam.Effect.ALLOW,
            actions=["iam:PassRole"],
            resources=[bedrock_service_role_arn],
        ))

        jobs_table.grant_read_write_data(self.execution_role)
        input_bucket.grant_read(self.execution_role)
        output_bucket.grant_read_write(self.execution_role)

        self.execution_role.add_to_policy(iam.PolicyStatement(
            effect=iam.Effect.ALLOW,
            actions=["states:SendTaskSuccess", "states:SendTaskFailure", "states:StartExecution"],
            resources=["*"],
        ))

        code = lambda_.Code.from_asset(LAMBDAS_DIR)
        runtime = lambda_.Runtime.PYTHON_3_13

        self.registrar_fn = lambda_.Function(
            self, "RegistrarFunction",
            function_name="bedrock-batch-sla-registrar",
            runtime=runtime,
            handler="registrar/index.handler",
            code=code,
            role=self.execution_role,
            environment={
                "JOBS_TABLE_NAME": jobs_table.table_name,
                "OUTPUT_BUCKET_NAME": output_bucket.bucket_name,
                "MODEL_ID": model_id,
                "STATE_MACHINE_ARN": "",  # Updated after state machine is created
            },
            timeout=cdk.Duration.seconds(60),
            memory_size=256,
            tracing=lambda_.Tracing.ACTIVE,
        )

        self.store_token_fn = lambda_.Function(
            self, "StoreTokenFunction",
            function_name="bedrock-batch-sla-store-token",
            runtime=runtime,
            handler="store-token/index.handler",
            code=code,
            role=self.execution_role,
            environment={
                "JOBS_TABLE_NAME": jobs_table.table_name,
                "MODEL_ID": model_id,
            },
            timeout=cdk.Duration.seconds(30),
            memory_size=128,
            tracing=lambda_.Tracing.ACTIVE,
        )

        self.resume_fn = lambda_.Function(
            self, "ResumeFunction",
            function_name="bedrock-batch-sla-resume",
            runtime=runtime,
            handler="resume/index.handler",
            code=code,
            role=self.execution_role,
            environment={
                "JOBS_TABLE_NAME": jobs_table.table_name,
            },
            timeout=cdk.Duration.seconds(60),
            memory_size=128,
            tracing=lambda_.Tracing.ACTIVE,
        )

        self.trigger_fn = lambda_.Function(
            self, "TriggerFunction",
            function_name="bedrock-batch-sla-trigger",
            runtime=runtime,
            handler="trigger/index.handler",
            code=code,
            role=self.execution_role,
            environment={
                "JOBS_TABLE_NAME": jobs_table.table_name,
                "MODEL_ID": model_id,
            },
            timeout=cdk.Duration.seconds(60),
            memory_size=256,
            tracing=lambda_.Tracing.ACTIVE,
        )

        self.reconcile_fn = lambda_.Function(
            self, "ReconcileFunction",
            function_name="bedrock-batch-sla-reconcile",
            runtime=runtime,
            handler="reconcile/index.handler",
            code=code,
            role=self.execution_role,
            environment={
                "OUTPUT_BUCKET_NAME": output_bucket.bucket_name,
            },
            timeout=cdk.Duration.seconds(300),
            memory_size=512,
            tracing=lambda_.Tracing.ACTIVE,
        )

        self.merge_fn = lambda_.Function(
            self, "MergeFunction",
            function_name="bedrock-batch-sla-merge",
            runtime=runtime,
            handler="merge/index.handler",
            code=code,
            role=self.execution_role,
            environment={
                "OUTPUT_BUCKET_NAME": output_bucket.bucket_name,
            },
            timeout=cdk.Duration.seconds(300),
            memory_size=512,
            tracing=lambda_.Tracing.ACTIVE,
        )

    def update_registrar_state_machine_arn(self, state_machine_arn: str) -> None:
        self.registrar_fn.add_environment("STATE_MACHINE_ARN", state_machine_arn)
