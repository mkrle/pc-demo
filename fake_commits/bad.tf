resource "aws_cloudwatch_log_group" "apache_bad" {
  name              = "apache[${count.index + 1}]"
  count             = "2"
  retention_in_days = 15
  tags = {
    yor_trace = "6346797b-cf15-457a-9f77-6cee30c6e2de"
  }
}
