FROM ubuntu:jammy
COPY wild.py /
RUN apt update -y
RUN apt install python3-pip git curl wget node-hawk node-minimist python3-boto3 awscli -y
RUN pip3 install gitpython azure-identity azure-storage-blob
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash   
EXPOSE 8080 
ENTRYPOINT [ "python3", "wild.py"]
