# Description:
#   Various Murano release automation
#
# Configuration:
#   RELEASE_GRAPHITE_HOST - Hostname for Graphite
#   RELEASE_GRAPHITE_PORT - Port for Graphite
#
# Commands:
#   hubot release downtime start - Indicate that release-related downtime has begun
#   hubot release downtime end - Indicate that release-related downtiem is over, and record the duration of that downtime as a Graphite metric
#   hubot release downtime 0 - Indicate that the most recently scheduled release resulted in no downtime
#   hubot release scheduled <HH:MM> - Indicate that a release is scheduled for the given time (UTC)
#   hubot release done - Indicate that the most recently scheduled release is finished, and record the duration of that release as a Graphite metric
#
# Author:
#   Dan Slimmon <dan.slimmon@gmail.com>
net = require('net')
https = require('https')
querystring = require('querystring')

os_host = process.env.RELEASE_OPENSHIFT_HOST
os_token = process.env.RELEASE_OPENSHIFT_TOKEN
os_port = 1*process.env.RELEASE_OPENSHIFT_PORT

graphite_host = process.env.RELEASE_GRAPHITE_HOST
graphite_port = 1*process.env.RELEASE_GRAPHITE_PORT

graphite_render_username = process.env.RELEASE_GRAPHITE_USERNAME
graphite_render_password = process.env.RELEASE_GRAPHITE_PASSWORD
graphite_render_host = process.env.RELEASE_GRAPHITE_RENDER_HOST
graphite_render_port = process.env.RELEASE_GRAPHITE_RENDER_PORT


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

# readGraphite() returns all data points for `target` within `interval` of
# the current time.
readGraphite = (target, interval, successCb, failureCb) ->
  auth_string = new Buffer("#{graphite_render_username}:#{graphite_render_password}").toString("base64")
  query_string = querystring.stringify({
    format: "json",
    target: target,
    from: "-#{interval}"
  })
  options = {
    host: graphite_render_host,
    port: graphite_render_port,
    method: "GET",
    path: "/render?#{query_string}",
    headers: {
      "Authorization": "Basic #{auth_string}",
      "Accept": "application/json"
    }
  }

  respBody = ""
  return https.request options, (resp) ->
    resp.on "data", (chunk) ->
      respBody = respBody + chunk
    resp.on "end", () ->
      if resp.statusCode != 200
        return failureCb new Error "Got #{resp.statusCode} response from API: #{respBody}"
      try
        bodyObj = JSON.parse respBody
        datapoints = bodyObj[0]["datapoints"]
        return successCb datapoints
      catch e
        return failureCb new Error "Error parsing Graphite response: #{e}"
  .on "error", (e) ->
    return failureCb e
  .end()

# timeSinceLastRelease() calculates the number of seconds since the most recent
# release, given the current date.
timeSinceLastRelease = (currentDate, successCb, failureCb) ->
  return readGraphite "release.duration", "90day", (datapoints) ->
    nonNullDatapoints = datapoints.filter (dp) ->
      dp[0] != null
    if nonNullDatapoints.length == 0
      return failureCb new Error "No previous release found in Graphite"
    lastDatapoint = nonNullDatapoints.pop()
    lastTimestamp = lastDatapoint[1]
    lastDate = new Date(lastTimestamp*1000)
    return successCb((currentDate - lastDate)/1000)
  , (e) ->
    return failureCb e

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

  # release scheduled
  #
  # Marks the time at which an upcoming Murano release is scheduled to take place
  #
  # It assumes that the time given is on the same (UTC) day as the current time.
  robot.respond /release scheduled ([0-9]{2}):([0-9]{2})$/i, (res) ->
    d = new Date
    d.setHours(1*res.match[1])
    d.setMinutes(1*res.match[2])
    d.setSeconds(0)
    d.setMilliseconds(0)
    isoDate = d.toISOString()
    robot.brain.set "releaseScheduled", isoDate
    res.send "Release scheduled for #{isoDate}"

  # release done
  #
  # Marks the end of a Murano release. Writes the duration of the release, in
  # seconds, to Graphite.
  robot.respond /release done$/i, (res) ->
    isoDate = robot.brain.get "releaseScheduled"
    d = Date.parse(isoDate)
    releaseSecs = ((new Date) - d) / 1000
    writeGraphite "release.duration", releaseSecs, d
    return timeSinceLastRelease(d, (since) ->
      writeGraphite "release.since", since, d
      res.send "Total release duration: #{releaseSecs} seconds\n\nTime since last release: #{since/3600} hours"
    , (e) ->
      res.send "Error retrieving time since last release from Graphite: #{e}"
    )

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

  # release downtime 0
  #
  # Indicates that no downtime occurred during a Murano release
  robot.respond /release downtime 0$/i, (res) ->
    isoDate = robot.brain.get "releaseScheduled"
    d = Date.parse(isoDate)
    writeGraphite "release.downtime", 0, d
    res.send "Nice! 0 seconds of downtime recorded"
