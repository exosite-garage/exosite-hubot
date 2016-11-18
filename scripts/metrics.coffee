# Description:
#   Various Murano release automation
#
# Configuration:
#   METRICS_GRAPHITE_HOST - Hostname for Graphite
#   METRICS_GRAPHITE_PORT - Port for Graphite
#   METRICS_PREFIX - Prefix for all metric names
#
# Commands:
#   hubot metrics write METRIC_NAME METRIC_VALUE [YYYY-mm-dd HH:MM] - Write the given value to the given Graphite metric, optionally specifying a time to override the default of the current time
#
# Author:
#   Dan Slimmon <dan.slimmon@gmail.com>
net = require('net')

graphite_host = process.env.METRICS_GRAPHITE_HOST
graphite_port = 1*process.env.METRICS_GRAPHITE_PORT
metric_prefix = process.env.METRICS_PREFIX

# writeGraphite() writes the given value to the given metric for the given timestamp.
#
# metricName will be prefixed with the METRICS_PREFIX environment variable.
writeGraphite = (metricName, value, timestamp) ->
  timestampInt = Math.floor(timestamp / 1000)
  client = new net.Socket
  client.connect graphite_port, graphite_host, () ->
    client.write "#{metric_prefix}.#{metricName} #{value} #{timestampInt}\n"
  client.on "drain", () ->
    client.close

module.exports = (robot) ->
  # release done
  #
  # Marks the end of a Murano release. Writes the duration of the release, in
  # seconds, to Graphite.
  robot.respond /metrics write ([A-Za-z0-9._-]+) ([0-9.]+)( .+)?$/i, (res) ->
    metricName = res.match[1]

    metricValue = 0.0
    try
      metricValue = parseFloat(res.match[2])
    catch e
      return res.send("Failed to parse metric value: #{e}")

    timestamp = new Date
    if res.match[3]? and res.match[3].length > 1
      dateString = res.match[3].trimLeft()
      try
        timestamp = new Date dateString
      catch e
        return res.send("Failed to parse timestamp: #{e}")

    writeGraphite metricName, metricValue, timestamp
    return res.send "Wrote to Graphite. Metric name: '#{metricName}'. Value: #{metricValue}. Time: #{timestamp.toISOString()}"
