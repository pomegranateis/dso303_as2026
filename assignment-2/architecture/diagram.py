"""Production architecture diagram (Task 1).

Regenerate:  pip install diagrams  (needs Graphviz), then
             python3 architecture/diagram.py   -> architecture/architecture.png
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import Lambda
from diagrams.aws.database import RDS, RDSPostgresqlInstance
from diagrams.aws.engagement import SimpleEmailServiceSes
from diagrams.aws.integration import Eventbridge, SimpleNotificationServiceSns, SimpleQueueServiceSqs
from diagrams.aws.management import Cloudtrail, Cloudwatch
from diagrams.aws.network import (APIGateway, CloudFront, Endpoint, InternetGateway, NATGateway,
                                  Route53)
from diagrams.aws.security import (CertificateManager, Cognito, KeyManagementService, SecretsManager,
                                   WAF)
from diagrams.aws.storage import Backup, SimpleStorageServiceS3
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users
from diagrams.onprem.iac import Terraform
from diagrams.onprem.vcs import Github

OUT = Path(__file__).with_name("architecture")

graph = {"fontsize": "22", "fontname": "Helvetica", "pad": "0.6", "nodesep": "0.45", "ranksep": "0.9",
         "splines": "spline", "compound": "true"}
node = {"fontsize": "12", "fontname": "Helvetica"}
edge = {"fontsize": "11", "fontname": "Helvetica"}

sync = {"color": "#1f4e8c"}
async_ = {"color": "#b5541b", "style": "dashed"}
ctl = {"color": "#7a7a7a", "style": "dotted"}

with Diagram("Online exam platform - production architecture (ap-south-1, two Availability Zones)",
             filename=str(OUT), outformat="png", show=False, direction="LR",
             graph_attr=graph, node_attr=node, edge_attr=edge):

    users = Users("Students, tutors,\nadministrators")

    with Cluster("Edge (global)"):
        dns = Route53("Route 53\nexams.<university>")
        waf = WAF("AWS WAF\nmanaged rules + rate limit")
        cdn = CloudFront("CloudFront\n/ -> app, /api/* -> API")
        acm = CertificateManager("ACM\nTLS certificate")

    with Cluster("Region ap-south-1"):
        cognito = Cognito("Cognito user pool\nstudents | tutors | admins")
        api = APIGateway("API Gateway (REST)\nCognito authorizer,\nthrottling")
        site = SimpleStorageServiceS3("S3 frontend\n(private, OAC)")
        uploads = SimpleStorageServiceS3("S3 uploads\nSSE-KMS, versioned,\nIA->Glacier->expire 5 y")

        with Cluster("VPC 10.20.0.0/16  (tiers left to right: public | private app | private data)"):
            igw = InternetGateway("Internet gateway")
            with Cluster("Availability Zone A"):
                with Cluster("Public 10.20.0.0/19"):
                    nat_a = NATGateway("NAT gateway A")
                with Cluster("Private app 10.20.64.0/19"):
                    fn_a = Lambda("Lambda ENIs A\nexam-api + workers")
                with Cluster("Private data 10.20.128.0/19"):
                    db_primary = RDSPostgresqlInstance("RDS PostgreSQL\nprimary")
            with Cluster("Availability Zone B"):
                with Cluster("Public 10.20.32.0/19"):
                    nat_b = NATGateway("NAT gateway B")
                with Cluster("Private app 10.20.96.0/19"):
                    fn_b = Lambda("Lambda ENIs B\nexam-api + workers")
                with Cluster("Private data 10.20.160.0/19"):
                    db_standby = RDSPostgresqlInstance("RDS PostgreSQL\nstandby")
            proxy = RDS("RDS Proxy\n(app subnets A+B)")
            endpoints = Endpoint("VPC endpoints\nS3, SQS, Secrets,\nEventBridge, KMS")

        with Cluster("Asynchronous processing"):
            q_up = SimpleQueueServiceSqs("uploads queue\n+ DLQ")
            q_mark = SimpleQueueServiceSqs("marking queue\n+ DLQ")
            bus = Eventbridge("EventBridge bus\nSubmissionReceived,\nResultsReleased")
            q_mail = SimpleQueueServiceSqs("email queue\n+ DLQ")
            ses = SimpleEmailServiceSes("SES\ne-mail")

        with Cluster("Security and operations"):
            secrets = SecretsManager("Secrets Manager\nDB credentials")
            kms = KeyManagementService("KMS\ncustomer key")
            cw = Cloudwatch("CloudWatch\nlogs, metrics,\nalarms, dashboard")
            sns = SimpleNotificationServiceSns("SNS\nops alerts")
            trail = Cloudtrail("CloudTrail\naudit")
            backup = Backup("AWS Backup\ndaily 35 d,\nmonthly 5 y")

    with Cluster("CI/CD"):
        repo = Github("GitHub\nmain branch")
        gha = GithubActions("GitHub Actions\nbuild, test, deploy")
        tf = Terraform("Terraform\ninfra/")

    # keep the tiers in the same order in both AZs
    invis = {"style": "invis"}
    nat_a >> Edge(**invis) >> fn_a >> Edge(**invis) >> db_primary
    nat_b >> Edge(**invis) >> fn_b >> Edge(**invis) >> db_standby

    # request path (walkthrough 1)
    users >> Edge(label="HTTPS", **sync) >> dns >> Edge(**sync) >> cdn
    waf - Edge(label="inspects", **ctl) - cdn
    acm - Edge(**ctl) - cdn
    cdn >> Edge(label="static app", **sync) >> site
    cdn >> Edge(label="/api/*", **sync) >> api
    users >> Edge(label="sign in", **sync) >> cognito
    api >> Edge(label="validate JWT", **ctl) >> cognito
    api >> Edge(**sync) >> [fn_a, fn_b]
    [fn_a, fn_b] >> Edge(label="SQL 5432", **sync) >> proxy >> Edge(**sync) >> db_primary
    db_primary >> Edge(label="synchronous replication", color="#1e7f4f", style="bold") >> db_standby

    # uploads and the asynchronous chain (walkthrough 2)
    users >> Edge(label="presigned POST (40 MB, not via API)", **async_) >> uploads
    uploads >> Edge(label="ObjectCreated", **async_) >> q_up
    [fn_a, fn_b] >> Edge(label="submit", **async_) >> q_mark
    q_up >> Edge(label="processor", **async_) >> bus
    bus >> Edge(label="SubmissionReceived", **async_) >> q_mail
    bus >> Edge(label="ResultsReleased", **async_) >> q_mark
    q_mark >> Edge(label="result jobs", **async_) >> q_mail
    q_mail >> Edge(label="notifier", **async_) >> ses
    ses >> Edge(label="tutor / student e-mail", **async_) >> users

    # supporting
    [fn_a, fn_b] >> Edge(**ctl) >> endpoints >> Edge(**ctl) >> secrets
    [nat_a, nat_b] >> Edge(**ctl) >> igw
    secrets - Edge(**ctl) - kms
    cw >> Edge(label="alarms", **ctl) >> sns
    backup >> Edge(label="snapshots", **ctl) >> db_primary

    # delivery
    repo >> Edge(label="push to main", **ctl) >> gha >> Edge(**ctl) >> tf >> Edge(label="terraform apply", **ctl) >> api
