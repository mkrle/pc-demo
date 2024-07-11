FROM ubuntu:jammy
COPY wild.py /
RUN apt update -y
RUN apt install python3-pip git curl wget node-hawk node-minimist -y
RUN pip3 --no-cache-dir install --upgrade awscli boto3
RUN pip3 install gitpython azure-identity azure-storage-blob
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash   
EXPOSE 8080 
ENTRYPOINT [ "python3", "wild.py"]
