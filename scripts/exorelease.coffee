net = require('net')
https = require('https')

os_host = process.env.RELEASE_OPENSHIFT_HOST
os_port = 1*process.env.RELEASE_OPENSHIFT_PORT
os_token = process.env.RELEASE_OPENSHIFT_TOKEN
graphite_host = process.env.RELEASE_GRAPHITE_HOST
graphite_port = 1*process.env.RELEASE_GRAPHITE_PORT


# tagImage() adds the given tag to the Docker image with the given ID.
tagImage = (imageId, tag, successCb, failureCb) ->
  options = {
    host: os_host,
    port: os_port,
    method: "GET",
    path: "/oapi/v1",
    headers: {
      "Authorization": "Bearer #{os_token}",
      "Accept": "application/json"
    }
  }

  respBody = ""
  https.request options, (resp) ->
    resp.on "data", (chunk) ->
      respBody = respBody + chunk
    resp.on "end", () ->
      if resp.statusCode != 200
        return failureCb new Error "Got #{resp.statusCode} response from API: #{respBody}"
      successCb()
  .on "error", (e) ->
    failureCb e
  .end()

writeGraphite = (metricName, value, timestamp) ->
  timestampInt = Math.floor(timestamp / 1000)
  client = new net.Socket
  client.connect graphite_port, graphite_host, () ->
    client.write "#{metricName} #{value} #{timestampInt}\n"
  client.on "drain", () ->
    client.close

module.exports = (robot) ->
  # qaready <image-id>
  #
  # Marks a docker image as ready for QA.
  robot.respond /qar(?:eady)? ([0-9a-f]+)$/i, (res) ->
    imageId = res.match[1]
    tagImage imageId, "qaready", () ->
      res.send "Marked image #{imageId} with tag 'qa-ready'"
    , (e) ->
      res.send "Error tagging image #{imageId}: #{e}"

  # release downtime start
  #
  # Marks the beginning of downtime caused by a Murano release.
  robot.respond /release downtime start$/i, (res) ->
    isoDate = (new Date).toISOString()
    robot.brain.set "downtimeStart", isoDate
    res.send "Downtime begins at #{isoDate}"

  # release downtime end
  #
  # Marks the end of downtime caused by a Murano release. Writes the duration of
  # the downtime, in seconds, to Graphite.
  robot.respond /release downtime end$/i, (res) ->
    isoDate = robot.brain.get "downtimeStart"
    d = Date.parse(isoDate)
    downtimeSecs = ((new Date) - d) / 1000
    writeGraphite "release.downtime", downtimeSecs, new Date
    res.send "Downtime recorded: #{downtimeSecs} seconds"
