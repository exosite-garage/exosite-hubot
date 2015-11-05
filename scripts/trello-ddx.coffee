# Description:
#   Manage your Trello differential diagnosis boards from Hubot
#
#   (based on https://github.com/hubot-scripts/hubot-trello by Jared Barboza)
#
# Dependencies:
#   "node-trello-ddx": "latest"
#
# Configuration:
#   HUBOT_DDX_KEY - Trello application key
#   HUBOT_DDX_TOKEN - Trello API token
#
# Commands:
#   hubot ddx start <problem description> - Start a new DDx board (and update room topic)
#   hubot ddx symptom <description> - Create a new DDx symptom
#   hubot ddx hypo <description> - Create a new DDx hypothesis
#   hubot ddx test <description> - Create a new DDx test
#   hubot ddx falsify <hypo_id> - Falsify a DDx hypothesis
#   hubot ddx finish <test_id> - Mark a DDx test finished
#
# Author:
#   Dan Slimmon <dan.slimmon@gmail.com>

Trello = require 'node-trello'

trello = new Trello process.env.HUBOT_DDX_KEY, process.env.HUBOT_DDX_TOKEN, process.env.HUBOT_DDX_ORGID

# verify that all the environment vars are available
ensureConfig = (out) ->
  out "Error: Trello app key is not specified" if not process.env.HUBOT_DDX_KEY
  out "Error: Trello token is not specified" if not process.env.HUBOT_DDX_TOKEN
  out "Error: Trello org ID is not specified" if not process.env.HUBOT_DDX_ORGID
  return false unless (process.env.HUBOT_DDX_KEY and process.env.HUBOT_DDX_TOKEN and process.env.HUBOT_DDX_ORGID)
  true

##############################
# API Methods
##############################

# brainKey returns a key under which to store brain data for this session
#
# `msg` should be a Response object (as passed to a robot.respond() callback)
brainKey = (msg) ->
  return "ddx_#{msg.envelope.room}"

# makeShortname returns a shortname with the given prefix and the given index
makeShortname = (prefix, ind) ->
  if ind < 10
    return "#{prefix}0#{ind}"
  return "#{prefix}#{ind}"

# startBoard creates a new DDx board and links to it in the chatroom topic
startBoard = (msg, problemDesc) ->
  msg.send "Starting DDx for issue '#{problemDesc}'..."
  ensureConfig msg.send
  boardName = "DDx: " + problemDesc
  board = null

  # 1. Create board
  trello.post "/1/boards", {
    name: boardName,
    idOrganization: process.env.HUBOT_DDX_ORGID,
    prefs_permissionLevel: "org",
    prefs_comments: "org"
  }, (err, data) ->
    if err
      console.log "Error creating DDx board: #{err}"
      msg.reply "Error creating DDx board: #{err}"
      return

    # 2. Add organization as board admin
    board = data
    trello.post "/1/board/#{board.id}/members/#{board.idOrganization}", {
      type: "admin"
    }, (err, data) ->
      if err
        console.log "Error making DDx board writable by the organization: #{err}"
        msg.reply "Error making DDx board writable by the organization: #{err}"
        return

      # 3. Retrieve initial list IDs
      trello.get "/1/boards/#{board.id}/lists", {}, (err, data) ->
        if err
          console.log "Error retreiving board's initial lists: #{err}"
          msg.reply "Error retreiving board's initial lists: #{err}"
          return

        # 4. Remove initial lists
        lists = data
        closeList = (listId, failure) ->
          trello.put "/1/lists/#{listId}/closed", {
            value: true
          }, (err, data) ->
            failure(err, data) if err
        closeFailureCb = (err, data) ->
          console.log "Error closing list: #{err}"
          msg.reply "Error closing list: #{err}"
        for list in lists
          closeList(list.id, closeFailureCb)

        # 5. Add DDx lists to board
        createList = (boardId, listName, listPos, failure, success) ->
          trello.post "/1/board/#{boardId}/lists", {
            name: listName,
            pos: listPos
          }, (err, data) ->
            if err
              failure(err, data)
            else
              success(err, data)
        createFailureCb = (err, data) ->
          console.log "Error creating list: #{err}"
          msg.reply "Error creating list: #{err}"
        ddxLists = {}
        createList board.id, "Symptoms", "bottom", createFailureCb, (err, data) ->
          ddxLists["Symptoms"] = {id: data.id, lastShortnameIndex: -1}
          createList board.id, "Hypotheses", "bottom", createFailureCb, (err, data) ->
            ddxLists["Hypotheses"] = {id: data.id, lastShortnameIndex: -1}
            createList board.id, "Tests", "bottom", createFailureCb, (err, data) ->
              ddxLists["Tests"] = {id: data.id, lastShortnameIndex: -1}
              # 6. Write board ID and list IDs to brain
              #
              # Brain entry has a key specific to the current room, and a value as follows:
              #
              # {
              #   boardId: <board ID>,
              #   lists: {
              #     Symptoms: {
              #       id: <symptom list ID>,
              #       lastShortnameIndex: <integer index of the most recent shortname>
              #     },
              #     Hypotheses: {
              #       id: <hypothesis list ID>,
              #       lastShortnameIndex: <integer index of the most recent shortname>
              #     },
              #     Tests: {
              #       id: <test list ID>,
              #       lastShortnameIndex: <integer index of the most recent shortname>
              #     }
              #   }
              # }
              brainEntry = {
                boardId: board.id,
                lists: ddxLists
              }
              msg.robot.brain.set brainKey(msg), brainEntry
              msg.robot.brain.save

              # 7. Report success
              msg.reply "Created DDx board: #{board.shortUrl}"
              msg.topic "[#{board.shortUrl}] #{problemDesc}"

# addSymptom creates a symptom on the active DDx board
addSymptom = (msg, sympDesc) ->
  ensureConfig msg.send
  brainEntry = msg.robot.brain.get(brainKey msg)
  list = brainEntry.lists.Symptoms
  if not list or not list.id
    msg.reply "Error: No 'Symptoms' list defined for the Trello board"

  brainEntry.lists.Symptoms.lastShortnameIndex += 1
  shortnameIndex = brainEntry.lists.Symptoms.lastShortnameIndex
  shortname = makeShortname "sy", shortnameIndex
  cardName = "[#{shortname}] #{sympDesc}"
  trello.post "/1/lists/#{list.id}/cards", {
    name: cardName,
    idList: list.id
  }, (err, data) ->
    if err
      console.log "Error creating the symptom '#{sympDesc}': #{err}"
      msg.reply "Error creating the symptom '#{sympDesc}': #{err}"
      return

    # Save to brain
    msg.robot.brain.set brainKey(msg), brainEntry
    msg.robot.brain.save

    # Report success
    msg.send "Created Symptom: #{cardName}"

# addHypo creates a hypothesis on the active DDx board
addHypo = (msg, hypoDesc) ->
  ensureConfig msg.send
  brainEntry = msg.robot.brain.get(brainKey msg)
  list = brainEntry.lists.Hypotheses
  if not list or not list.id
    msg.reply "Error: No 'Hypotheses' list defined for the Trello board"

  brainEntry.lists.Hypotheses.lastShortnameIndex += 1
  shortnameIndex = brainEntry.lists.Hypotheses.lastShortnameIndex
  shortname = makeShortname "hy", shortnameIndex
  cardName = "[#{shortname}] #{hypoDesc}"
  trello.post "/1/lists/#{list.id}/cards", {
    name: cardName,
    idList: list.id
  }, (err, data) ->
    if err
      console.log "Error creating the hypothesis '#{hypoDesc}': #{err}"
      msg.reply "Error creating the hypothesis '#{hypoDesc}': #{err}"
      return

    # Save to brain
    msg.robot.brain.set brainKey(msg), brainEntry
    msg.robot.brain.save

    # Report success
    msg.send "Created Hypothesis: #{cardName}"

# addTest creates a test on the active DDx board
addTest = (msg, testDesc) ->
  ensureConfig msg.send
  brainEntry = msg.robot.brain.get(brainKey msg)
  list = brainEntry.lists.Tests
  if not list or not list.id
    msg.reply "Error: No 'Tests' list defined for the Trello board"

  brainEntry.lists.Tests.lastShortnameIndex += 1
  shortnameIndex = brainEntry.lists.Tests.lastShortnameIndex
  shortname = makeShortname "te", shortnameIndex
  cardName = "[#{shortname}] #{testDesc}"
  trello.post "/1/lists/#{list.id}/cards", {
    name: cardName,
    idList: list.id
  }, (err, data) ->
    if err
      console.log "Error creating the test '#{testDesc}': #{err}"
      msg.reply "Error creating the test '#{testDesc}': #{err}"
      return

    # Save to brain
    msg.robot.brain.set brainKey(msg), brainEntry
    msg.robot.brain.save

    # Report success
    msg.send "Created Test: #{cardName}"

moveCard = (msg, card_id, list_name) ->
  ensureConfig msg.send
  id = lists[list_name.toLowerCase()].id
  msg.reply "I couldn't find a list named: #{list_name}." unless id
  if id
    trello.put "/1/cards/#{card_id}/idList", {value: id}, (err, data) ->
      msg.reply "Sorry boss, I couldn't move that card after all." if err
      msg.reply "Yep, ok, I moved that card to #{list_name}." unless err

module.exports = (robot) ->
  # fetch our board data when the script is loaded
  ensureConfig console.log

  # Regexes match any unambiguous prefix of a command (e.g. "start" can be shortened
  # to "st" but not "s"
  robot.respond /ddx st.*? (.+)/i, (msg) ->
    ensureConfig msg.send
    return unless ensureConfig()
    startBoard msg, msg.match[1]

  robot.respond /ddx sy.*? (.+)/i, (msg) ->
    addSymptom msg, msg.match[1]

  robot.respond /ddx hy.*? (.+)/i, (msg) ->
    addHypo msg, msg.match[1]

  robot.respond /ddx t.*? (.+)/i, (msg) ->
    addTest msg, msg.match[1]

  robot.respond /trello move (\w+) ["'](.+)["']/i, (msg) ->
    moveCard msg, msg.match[1], msg.match[2]

  robot.respond /trello list lists/i, (msg) ->
    msg.reply "Here are all the lists on your board."
    Object.keys(lists).forEach (key) ->
      msg.send " * " + key

  robot.respond /trello help/i, (msg) ->
    msg.reply "Here are all the commands for me."
    msg.send " *  trello new \"<ListName>\" <TaskName>"
    msg.send " *  trello list \"<ListName>\""
    msg.send " *  shows * [<card.shortLink>] <card.name> - <card.shortUrl>"
    msg.send " *  trello move <card.shortlink> \"<ListName>\""
    msg.send " *  trello list lists"

