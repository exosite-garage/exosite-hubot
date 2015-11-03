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
#   hubot ddx link - Echo a link to the actie DDx board
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
        console.log JSON.stringify board
        for list in lists
          closeList(list.id, closeFailureCb)

        # 5. Add  DDx lists to board
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
        createList board.id, "Symptoms", "bottom", createFailureCb, (err, data) ->
          createList board.id, "Hypotheses", "bottom", createFailureCb, (err, data) ->
            createList board.id, "Tests", "bottom", createFailureCb, (err, data) ->
              msg.reply "Created DDx board: #{board.shortUrl}"
              msg.topic "[#{board.shortUrl}] #{problemDesc}"


createCard = (msg, list_name, cardName) ->
  msg.reply "Sure thing boss. I'll create that card for you."
  ensureConfig msg.send
  id = lists[list_name.toLowerCase()].id
  trello.post "/1/cards", {name: cardName, idList: id}, (err, data) ->
    msg.reply "There was an error creating the card" if err
    msg.reply "OK, I created that card for you. You can see it here: #{data.url}" unless err

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

  robot.respond /ddx start (.+)/i, (msg) ->
    console.log msg
    ensureConfig msg.send
    problemDesc = msg.match[1]
    return unless ensureConfig()
    startBoard msg, problemDesc

  robot.respond /trello list ["'](.+)["']/i, (msg) ->
    showCards msg, msg.match[1]

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

