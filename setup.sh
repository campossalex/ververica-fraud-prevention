#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

HELM=${HELM:-helm}
VVP_CHART=${VVP_CHART:-}
VVP_CHART_VERSION=${VVP_CHART_VERSION:-"5.8.1"}

VVP_NAMESPACE=${VVP_NAMESPACE:-vvp}
JOBS_NAMESPACE=${JOBS_NAMESPACE:-"vvp-jobs"}

usage() {
  echo "This script installs Ververica Platform as well as its dependencies into a Kubernetes cluster using Helm."
  echo
  echo "Usage:"
  echo "  $0 [flags]"
  echo
  echo "Flags:"
  echo "  -h, --help"
  echo "  -e, --edition [community|enterprise] (default: commmunity)"
  echo "  -m, --with-metrics"
  echo "  -l, --with-logging"
}

create_namespaces() {
  # Create the vvp system and jobs namespaces if they do not exist
  kubectl get namespace "$VVP_NAMESPACE" > /dev/null 2>&1 || kubectl create namespace "$VVP_NAMESPACE"
  kubectl get namespace "$JOBS_NAMESPACE" > /dev/null 2>&1 || kubectl create namespace "$JOBS_NAMESPACE"
}

helm_install() {
  local name chart namespace

  name="$1"; shift
  chart="$1"; shift
  namespace="$1"; shift

  $HELM \
    --namespace "$namespace" \
    upgrade --install "$name" "$chart" \
    "$@"
}

install_minio() {
  helm \
    --namespace "vvp" \
    upgrade --install "minio" "minio" \
    --repo https://charts.helm.sh/stable \
    --values /root/ververica-platform-playground/setup/helm/values-minio.yaml
}

install_grafana() {
  helm_install grafana grafana "$VVP_NAMESPACE" \
    --repo https://grafana.github.io/helm-charts \
    --values /root/ververica-platform-playground/setup/helm/values-grafana.yaml
}

helm_install_vvp() {
  if [ -n "$VVP_CHART" ];  then
    helm_install vvp "$VVP_CHART" "$VVP_NAMESPACE" \
      --version "$VVP_CHART_VERSION" \
      --values /root/ververica-platform-playground/setup/helm/values-vvp.yaml \
      --set rbac.additionalNamespaces="{$JOBS_NAMESPACE}" \
      --set vvp.blobStorage.s3.endpoint="http://minio.$VVP_NAMESPACE.svc:9000" \
      "$@"
  else
    helm_install vvp ververica-platform "$VVP_NAMESPACE" \
      --repo https://charts.ververica.com \
      --version "$VVP_CHART_VERSION" \
      --values /root/ververica-platform-playground/setup/helm/values-vvp.yaml \
      --set rbac.additionalNamespaces="{$JOBS_NAMESPACE}" \
      --set vvp.blobStorage.s3.endpoint="http://minio.$VVP_NAMESPACE.svc:9000" \
      "$@"
  fi
}

prompt() {
  local yn
  read -r -p "$1 (y/N) " yn

  case "$yn" in
  y | Y)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

install_vvp() {
  local edition install_metrics install_logging helm_additional_parameters

  edition="$1"
  install_metrics="$2"
  install_logging="$3"
  helm_additional_parameters=
  
  if [ "$edition" == "enterprise" ]; then
    echo "Installing Enterprise..."
    helm_install_vvp \
      --values /root/ververica-platform-playground/setup/helm/values-license.yaml \
      $helm_additional_parameters
  else
    # try installation once (aborts and displays license)
    helm_install_vvp $helm_additional_parameters

    echo "Installing Community..."
    helm_install_vvp \
      --set acceptCommunityEditionLicense=true \
      $helm_additional_parameters

  fi

}

main() {
  local edition install_metrics install_logging

  # defaults
  edition="community"
  install_metrics=
  install_logging=

  # parse params
  while [[ "$#" -gt 0 ]]; do case $1 in
    -e|--edition) edition="$2"; shift; shift;;
    -m|--with-metrics) install_metrics=1; shift;;
    -l|--with-logging) install_logging=1; shift;;
    -h|--help) usage; exit;;
    *) usage ; exit 1;;
  esac; done

  # verify params
  case $edition in
    "enterprise"|"community")
      ;;
    *)
      echo "ERROR: unknown edition \"$edition\""
      echo
      usage
      exit 1
  esac

  echo "> Setting up Ververica Platform Playground in namespace '$VVP_NAMESPACE' with jobs in namespace '$JOBS_NAMESPACE'"
  echo "> The currently configured Kubernetes context is: $(kubectl config current-context)"

  echo "> Creating Kubernetes namespaces..."
  create_namespaces

  echo "> Installing Grafana..."
  install_grafana || :
    
  echo "> Installing MinIO..."
  install_minio || :

  echo "> Installing Ververica Platform..."
  install_vvp "$edition" "$install_metrics" "$install_logging" || :

  echo "> Waiting for all Deployments and Pods to become ready..."
  kubectl --namespace "$VVP_NAMESPACE" wait --timeout=5m --for=condition=available deployments --all
  kubectl --namespace "$VVP_NAMESPACE" wait --timeout=5m --for=condition=ready pods --all

  echo "> Successfully set up the Ververica Platform Playground"

  # Nodeport to access VVP and Grafana from browser
  echo "> Applying NodePort configuration..."
  kubectl patch service vvp-ververica-platform -n vvp -p '{"spec": { "type": "NodePort", "ports": [ { "nodePort": 30002, "port": 80, "protocol": "TCP", "targetPort": 8080, "name": "vvp-np" } ] } }'
  kubectl patch service grafana -n vvp -p '{"spec": { "type": "NodePort", "ports": [ { "nodePort": 30003, "port": 80, "protocol": "TCP", "targetPort": 3000, "name": "grafana-np" } ] } }'
  kubectl patch service minio -n vvp -p '{"spec": { "type": "NodePort", "ports": [ { "nodePort": 30004, "port": 9000, "protocol": "TCP", "targetPort": 9000, "name": "minio-np" } ] } }'

  # port-forward setup
  screen -dmS vvp bash -c 'kubectl --address 0.0.0.0 --namespace vvp port-forward services/vvp-ververica-platform 8080:80'
  screen -dmS grafana bash -c 'kubectl --address 0.0.0.0 --namespace vvp port-forward services/grafana 8085:80'
  screen -dmS minio bash -c 'kubectl --address 0.0.0.0 --namespace vvp port-forward services/minio 9000:9000'

  # Waiting VVP to respond
  echo "> Waiting VVP to be ready..."
  while ! curl --silent --fail --output /dev/null localhost:8080/api/v1/status 
  do
      sleep 1 
  done

  # Create Deployment Target and Session Cluster
  curl -i -X POST localhost:8080/api/v1/namespaces/default/deployment-targets -H "Content-Type: application/yaml" --data-binary "@/root/ververica-platform-playground/vvp-resources/deployment_target.yaml"
  curl -i -X POST localhost:8080/api/v1/namespaces/default/sessionclusters -H "Content-Type: application/yaml" --data-binary "@/root/ververica-platform-playground/vvp-resources/sessioncluster.yaml"
  curl -i -X POST 'localhost:8080/namespaces/v1/namespaces/default:setPreviewSessionCluster' -H 'accept: application/json' -H 'Content-Type: application/json' -d '{"previewSessionClusterName": "sql-editor"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"CREATE TABLE `transactions` (
  `txId` STRING,
  `cardId` STRING,
  `cardNumber` STRING,
  `cardBrand` STRING,
  `accountId` STRING,
  `amount` DECIMAL(12, 2),
  `currency` STRING,
  `merchantId` STRING,
  `country` STRING,
  `eventTime` BIGINT,
  `event_ts` AS TO_TIMESTAMP_LTZ(`eventTime`, 3),
  WATERMARK FOR `event_ts` AS `event_ts` - INTERVAL '\''1'\'' SECOND
) WITH (
  '\''connector'\'' = '\''kafka'\'',
  '\''format'\'' = '\''json'\'',
  '\''json.ignore-parse-errors'\'' = '\''true'\'',
  '\''properties.bootstrap.servers'\'' = '\''host.minikube.internal:9092'\'',
  '\''properties.group.id'\'' = '\''flink-fraud-detector'\'',
  '\''scan.startup.mode'\'' = '\''earliest-offset'\'',
  '\''topic'\'' = '\''transactions'\''
);

CREATE TABLE `alerts` (
  `alertId` STRING,
  `card_hash` STRING,
  `country` STRING,
  `transaction_id` STRING,
  `rule` STRING,
  `score` DOUBLE,
  `details` STRING,
  `alertTime` TIMESTAMP(3) WITH LOCAL TIME ZONE
) WITH (
  '\''connector'\'' = '\''kafka'\'',
  '\''format'\'' = '\''json'\'',
  '\''properties.bootstrap.servers'\'' = '\''host.minikube.internal:9092'\'',
  '\''properties.group.id'\'' = '\''flink-fraud-alert'\'',
  '\''scan.startup.mode'\'' = '\''earliest-offset'\'',
  '\''topic'\'' = '\''alerts'\''
);","displayName":"1. Kafka Table DDL","name":"namespaces/default/sqlscripts/kafka-table-ddl"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"SELECT * FROM `transactions` (
);","displayName":"2. Query transaction table","name":"namespaces/default/sqlscripts/kafka-table-ddl"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"
CREATE VIEW `card_5m`
AS SELECT `cardId`, `country`, `window_start`, `window_end`, COUNT(*) AS `tx_count`, SUM(`amount`) AS `amount_sum`
FROM TABLE(TUMBLE(TABLE `transactions`, DESCRIPTOR(`event_ts`), INTERVAL '\''5'\'' MINUTE))
GROUP BY `cardId`, `country`, `window_start`, `window_end`;

CREATE VIEW `travel_matches`
AS SELECT `cardId`, `txId1`, `txId2`, `country1`, `country2`, `ts1`, `ts2`
FROM `transactions` MATCH_RECOGNIZE(
PARTITION BY `cardId`
ORDER BY `event_ts`
MEASURES `A`.`txId` AS `txId1`, `B`.`txId` AS `txId2`, `A`.`country` AS `country1`, `B`.`country` AS `country2`, `A`.`event_ts` AS `ts1`, `B`.`event_ts` AS `ts2`
ONE ROW PER MATCH
AFTER MATCH SKIP TO LAST `B`
PATTERN (`A` `B`)
DEFINE `B` AS `B`.`country` <> `A`.`country` AND `B`.`event_ts` <= `A`.`event_ts` + INTERVAL '\''10'\'' MINUTE);
","displayName":"3. Views DDL","name":"namespaces/default/sqlscripts/view-ddl"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"INSERT INTO alerts
SELECT
  CONCAT('\''travel-'\'', cardId, '\''-'\'', txId2) AS alertId,
  cardId AS cardId,
  country1,
  txId2 AS txId,
  '\''IMPOSSIBLE_TRAVEL'\'' AS rule,
  0.95 AS score,
  CONCAT(
    '\''{\"from\":\"'\'', country1,
    '\''\",\"to\":\"'\'', country2,
    '\''\",\"prevTxId\":\"'\'', txId1,
    '\''\",\"delta_minutes\":'\'', CAST(TIMESTAMPDIFF(MINUTE, ts1, ts2) AS STRING),
    '\''}'\''
  ) AS details,
  ts2 AS alertTime
FROM travel_matches;
","displayName":"4. Create Impossible Travel Rule","name":"namespaces/default/sqlscripts/impossible-travel-rule"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"INSERT INTO alerts
SELECT
  CONCAT('\''vel-'\'', cardId, '\''-'\'', DATE_FORMAT(window_end, '\''yyyyMMddHHmm'\'')) AS alertId,
  cardId AS cardId,
  country,
  CAST(NULL AS STRING) AS txId,
  '\''VELOCITY_BURST_5M'\'' AS rule,
  LEAST(0.99, 0.60 + 0.05 * tx_count) AS score,
  CONCAT('\''{\"tx_count\":'\'', CAST(tx_count AS STRING),
         '\'',\"amount_sum\":'\'', CAST(amount_sum AS STRING), 
         '\'',\"start\":\"'\'', CAST(window_start AS STRING),
         '\''\",\"end\":\"'\'', CAST(window_end AS STRING),
         '\''\"}'\'') AS details,
  window_end AS alertTime
FROM card_5m
WHERE tx_count >= 5 OR amount_sum >= 1200;
","displayName":"5. Create Velocity Rule","name":"namespaces/default/sqlscripts/velocity-rule"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"INSERT INTO alerts
SELECT
  CONCAT('\''high-value-'\'', cardId, '\''-'\'', txId) AS alertId,
  cardId,
  country,
  txId,
  '\''HIGH_VALUE'\'' AS rule,
  LEAST(0.99, 0.70 + (CAST(amount AS DOUBLE) / 50000.0)) AS score,
  CONCAT(
    '\''{\"amount\":'\'', CAST(amount AS STRING),
    '\'',\"currency\":\"'\'', currency,
    '\''\",\"merchantId\":\"'\'', merchantId,
    '\''\",\"country\":\"'\'', country,
    '\''\"}'\''
  ) AS details,
  CAST(event_ts AS TIMESTAMP(3) WITH LOCAL TIME ZONE) AS alertTime
FROM transactions 
WHERE amount > 5000.00;
","displayName":"6. Create High Value Rule","name":"namespaces/default/sqlscripts/high-value-rule"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"SELECT * FROM `alerts` (
);","displayName":"7. Query alert table","name":"namespaces/default/sqlscripts/kafka-table-ddl"}'


curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"CREATE CATALOG fraud WITH (
  '\''type'\'' = '\''jdbc'\'',
  '\''base-url'\'' = '\''jdbc:postgresql://host.minikube.internal:5432'\'',
  '\''default-database'\'' = '\''fraud'\'',
  '\''username'\'' = '\''root'\'',
  '\''password'\'' = '\''admin1'\''
)","displayName":"8. Create a Postgre Catalog","name":"namespaces/default/sqlscripts/create-catalog"}'

curl -X POST "localhost:8080/sql/v1beta1/namespaces/default/sqlscripts" \
  -H "Content-Type: application/json" \
  -d '{"script":"INSERT INTO fraud.fraud.alerts 
SELECT * FROM alerts",
"displayName":"9. Sink Kafka Alerts to Postgres","name":"namespaces/default/sqlscripts/alerts-sink"}'

}

main "$@"
