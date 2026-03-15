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

Lab 1: Connecting with Data Sources
===
In this first lab, you will learn how to create Dynamic Table to consume data from a Kafka topic and from a CSV file stored in Minio (s3).

To go Ververica Web console, then SQL -> SQL scripts. Run in order the Scripts you will find the left-hand side of the SQL Editor. 
