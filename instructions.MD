Getting Familiar
===

The following tools and components were deployed to build the streaming application as part of this Lab Day:

- **Ververica**: access the Ververica Unified Streaming Data Platform web console to run Flink jobs.
- **Redpanda**: Redpanda Console will give access to the Kafka broker where the business events will come in.
- **Grafana**: access Grafana to design, build and publish a dashboard.

Additionally, you have access to two command line interfaces to run some commands.

> [!NOTE]
> Use the following credentials to connect to the Postgres database:
> - **User**: root
> - **Password**: admin1

> [!NOTE]
> Please skip the license message you will see in the different components. This lab environment is for training purposes, so licenses are not required.

Steps
===

To go Ververica Web console, then SQL -> SQL scripts. Run in order the Scripts you will find the left-hand side of the SQL Editor.  

Steps description:  

1. Create the Dynamic Tables to connect to the Kafka cluster. Two tables are created: transactions and alerts.  
2. Query the transaction table (Kafka topic) to print some records.  
3. Create VIEWS to group events by rules.  
4. Create the Rule to detect Impossible Travels (transactions in two different countries in less than 10 minutes).  
5. Create the Rule to detect Velocity patterns (transactions_count >= 5 OR amount_sum >= 1200).  
6. Create the Rule to detect Highe Value ( transaction amount >= 5000).  
7. Query the alert table (Kafka topic) to print some records.  
8. Create a new Catalog to connect to the Postgres database.  
8. Create a job to sink the alerts from the Kafka topic to the Postgres table.  
