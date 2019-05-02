fs = require 'fs'
path = require 'path'
util = require 'util'
child_process = require 'child_process'
assert = require 'assert'

{ JSONValidator } = require('../../parser/jsonValidator').lib


testObjectsEqual = (a, b) ->
  if Array.isArray a
    unless Array.isArray b
      throw "#{JSON.stringify a} NOT EQUAL TO #{JSON.stringify b}"

    unless a.length == b.length
      throw "#{JSON.stringify a} NOT EQUAL TO #{JSON.stringify b}"

    for v, i in a
      testObjectsEqual v, b[i]
    return

  if typeof(a) == 'object'
    unless typeof(b) == 'object'
      throw "#{JSON.stringify a} NOT EQUAL TO #{JSON.stringify b}"

    # check all B keys are present in A, as long as B key actually has a value
    for k, v of b
      continue unless v?
      unless k of a
        throw "#{JSON.stringify a} NOT EQUAL TO #{JSON.stringify b}"

    # check that all values in A are the same in B
    for k, v of a
      testObjectsEqual v, b[k]
    return

  unless a == b
    throw "#{JSON.stringify a} NOT EQUAL TO #{JSON.stringify b}"


logger = console
writeFilePromise = util.promisify fs.writeFile
exec = util.promisify child_process.exec

module.exports =
  deploy: (context, overrideLogger) ->
    logger = overrideLogger
    manifestContext = {}

    logger.log "beginning manifest deployment"

    loadSkillInfo context, manifestContext
    .then ->
      buildSkillManifest context, manifestContext
    .then ->
      createOrUpdateSkill context, manifestContext
    .then ->
      updateModel context, manifestContext
    .then ->
      enableSkill context, manifestContext
    .then ->
      loadIspData context, manifestContext
    .then ->
      createOrUpdateIspData context, manifestContext
    .then ->
      logger.log "manifest deployment complete, #{logger.runningTime()}ms"
    .catch (error) ->
      if error?.code? or error?.error?
        logger.error if error.error? then error.error else error.code
        throw "SMAPI: #{error.code ? ''} #{error.error}"
      else
        if error.stack?
          logger.error error.stack
        else
          logger.error JSON.stringify error
        throw "failed manifest deployment"


loadSkillInfo = (context, manifestContext) ->
  logger.log "loading skill.json"
  infoFilename = path.join context.projectRoot, 'skill'

  try
    manifestContext.info = require infoFilename
  catch err
    if err.code == 'MODULE_NOT_FOUND'
      writeDefaultManifest(context, path.join context.projectRoot, 'skill.coffee')
      throw "skill.* was not found in project root #{context.projectRoot}, so a default has been
        generated in CoffeeScript. Please modify as appropriate and try deployment again."
    logger.error err
    throw "Failed to parse skill manifest #{infoFilename}"
  Promise.resolve()


buildSkillManifest = (context, manifestContext) ->
  logger.log "building skill manifest"
  unless 'manifest' of manifestContext.info
    throw "didn't find a `manifest` property in the skill.* file. Has it been corrupted?"

  info = manifestContext.info.manifest

  lambdaArn = context.artifacts.get 'lambdaARN'
  unless lambdaArn
    throw "Missing lambda ARN during manifest deployment. Has the Lambda deployed yet?"

  manifest =
    manifestVersion: "1.0"
    publishingInformation:
      isAvailableWorldwide: false,
      distributionCountries: [ 'US' ]
      distributionMode: 'PUBLIC'
      category: 'GAMES'
      testingInstructions: 'no instructions'
      gadgetSupport: undefined
    privacyAndCompliance:
      allowsPurchases: false
      usesPersonalInfo: false
      isChildDirected: false
      isExportCompliant: true
      containsAds: false
    apis:
      custom:
        endpoint:
          uri: lambdaArn
        regions:
          NA:
            endpoint:
              uri: lambdaArn
        interfaces: []
    #events: {}
    #permissions: {}

  unless 'publishingInformation' of info
    throw "skill.json is missing publishingInformation.
      Has it been corrupted?"

  interfaces = manifest.apis.custom.interfaces

  for key of info
    switch key
      when 'publishingInformation'

        # copy over all sub keys of publishing information
        for k, v of manifest.publishingInformation
          manifest.publishingInformation[k] = info.publishingInformation[k] ? v

        unless 'locales' of info.publishingInformation
          throw "skill.json is missing locales in publishingInformation.
            Has it been corrupted?"

        # apply the default icon location, unless intentionally overriden
        requiredAssets = context.artifacts.get('required-assets') ? {}
        manifestContext.assetsMd5 = ""
        iconURLs = for name in ['icon-108.png', 'icon-512.png']
          assetInfo = requiredAssets[name]
          unless assetInfo?
            throw "missing #{name} in the assets directory, or you haven't deployed it with the
              assets yet. Please remedy and try again."
          manifestContext.assetsMd5 += assetInfo.md5
          assetInfo.url


        # dig through specified locales. TODO: compare with code language support?
        manifest.publishingInformation.locales = {}
        manifestContext.locales = []
        for locale, data of info.publishingInformation.locales
          # copy over kosher keys, ignore the rest
          whitelist = ['name', 'summary', 'description'
            'examplePhrases', 'keywords', 'smallIconUri',
            'largeIconUri']
          copy = {}
          for k in whitelist
            copy[k] = data[k]
          copy.smallIconUri = copy.smallIconUri ? iconURLs[0]
          copy.largeIconUri = copy.largeIconUri ? iconURLs[1]
          manifest.publishingInformation.locales[locale] = copy

          invocationName = context.deploymentOptions.invocation?[locale] ? data.invocation ? data.name
          invocationName = invocationName.replace /[^a-zA-Z0-9 ]/g, ' '
          invocationName = invocationName.toLowerCase()

          if context.deploymentOptions.invocationSuffix?
            invocationName += " #{context.deploymentOptions.invocationSuffix}"

          maxLength = 160
          if copy.summary.length > maxLength
            copy.summary = copy.summary[0..maxLength - 4] + '...'
            logger.log "uploaded summary length: #{copy.summary.length}"
            logger.warning "summary for locale #{locale} was too long, truncated it to #{maxLength}
              characters"

          unless copy.examplePhrases
            copy.examplePhrases = [
              "Alexa, launch <invocation>"
              "Alexa, open <invocation>"
              "Alexa, play <invocation>"
            ]

          copy.examplePhrases = for phrase in copy.examplePhrases
            phrase.replace /\<invocation\>/gi, invocationName

          if context.projectInfo.variant != 'production'
            copy.name += " (#{context.projectInfo.variant})"

          manifestContext.locales.push {
            code: locale
            invocation: invocationName
          }

        unless manifestContext.locales.length > 0
          throw "no locales found in the skill.json manifest. Please add at least one."

      when 'privacyAndCompliance'
        # dig through these too
        for k, v of manifest.privacyAndCompliance
          manifest.privacyAndCompliance[k] = info.privacyAndCompliance[k] ? v

        if info.privacyAndCompliance.locales?
          manifest.privacyAndCompliance.locales = {}
          for locale, data of info.privacyAndCompliance.locales
            manifest.privacyAndCompliance.locales[locale] =
              privacyPolicyUrl: data.privacyPolicyUrl
              termsOfUseUrl: data.termsOfUseUrl

      when 'apis'
        # copy over any keys the user has specified, they might know some
        # advanced information that hasn't been described in a plugin yet,
        # trust the user on this
        if info.apis?.custom?.interfaces?
          for i in info.apis.custom.interfaces
            interfaces.push i

      else
        # no opinion on any remaining keys, so if they exist, copy them over
        manifest[key] = info[key]

  # collect which APIs are actually in use and merge them
  requiredAPIs = {}
  context.skill.collectRequiredAPIs requiredAPIs
  for apiName of requiredAPIs
    found = false
    for i in interfaces
      if i.type == apiName
        found = true
    unless found
      logger.log "enabling interface #{apiName}"
      interfaces.push { type: apiName }

  # save it for later, wrap it one deeper for SMAPI
  manifestContext.manifest = manifest
  manifest = { manifest: manifest }

  # extensions can opt to validate the manifest, in case there are other
  # dependencies they want to assert
  for extensionName, extension of context.projectInfo.extensions
    validator = new JSONValidator manifest
    extension.compiler?.validators?.manifest validator, context.skill
    if validator.errors.length > 0
      logger.error e for e in validator.errors
      throw new Error "Errors encountered with the manifest, cannot continue."

  # now that we have the manifest, we can also validate the models
  for region of manifest.manifest.publishingInformation.locales
    model = context.skill.toModelV2(region)
    validator = new JSONValidator model
    for extensionName, extension of context.projectInfo.extensions
      extension.compiler?.validators?.model validator, manifest, context.skill
      if validator.errors.length > 0
        logger.error e for e in validator.errors
        throw new Error "Errors encountered with model in #{region} language, cannot continue"

  manifestContext.manifestFilename = path.join(context.deployRoot, 'skill.json')
  writeFilePromise manifestContext.manifestFilename, JSON.stringify(manifest, null, 2), 'utf8'


callSMAPI = (context, command, parameters) ->
  call = [ 'ask', 'api', command ]

  unless context.deploymentOptions?.askProfile?
    throw "couldn't find `askProfile` in the '#{context.deploymentName}' deployment parameters from
      this project's config file. Please set it to the ask-cli profile you'd like to use."

  call.push '--profile'
  call.push context.deploymentOptions.askProfile

  for k, v of parameters
    call.push "--#{k}"
    call.push '"' + v + '"'

  logger.verbose call.join ' '

  exec call.join(' '), {maxBuffer: 1024 * 1024}
  .then (data) ->
    if data.stdout.toLowerCase().indexOf("command not recognized") >= 0
      throw "#{command} was reported as not a valid ask-cli command.
        Please ensure you have the latest version "

    logger.verbose "SMAPI #{command} complete #{data.stdout}"
    logger.verbose "SMAPI stderr: " + data.stderr
    if data.stderr and data.stderr.indexOf('ETag') < 0
      throw data.stderr
    Promise.resolve data.stdout
  .catch (err) ->
    logger.verbose err
    logger.verbose "failed to call #{command} during manifest deployment"
    statusCode = null
    errorMessage = null
    errorText = "" + err
    if errorText.match /ask\s*:\s*command not found/i
      errorMessage = 'ask command not found. Is ask-cli correctly installed and configured?'
    else if errorText.match /\s*Cannot resolve profile/i
      errorMessage = "ASK profile not found. Make sure the profile:
        '#{context.deploymentOptions.askProfile}' exists and is set up correctly."
    else
      try
        lines = errorText.split '\n'
        for line in lines
          k = line.split(':')[0] ? ''
          v = (line.replace k, '')[1..].trim()
          k = k.trim()
          if k.toLowerCase().indexOf('error code') == 0
            statusCode = parseInt v
          else if k == '"message"'
            errorMessage = v.trim()
      catch err
        logger.error "failed to extract failure status code from SMAPI call"

    unless statusCode?
      statusCode = -1

    unless errorMessage?
      msg = err
      if typeof(err) == 'object'
        msg = JSON.stringify msg
      errorMessage = "Unknown SMAPI error, failed to execute #{command}: #{msg}"

    throw { code: statusCode, error: errorMessage }


createOrUpdateSkill = (context, manifestContext) ->
  skillId = context.artifacts.get 'skillId'
  if skillId?
    manifestContext.skillId = skillId
    logger.log "skillId found in artifacts, getting information"
    updateSkill context, manifestContext
  else
    logger.log "no skillId found in artifacts, creating new skill"
    createSkill context, manifestContext


parseSkillInfo = (data) ->
  try
    data = JSON.parse data
  catch err
    logger.verbose data
    logger.error err
    throw "failed to parse JSON response from SMAPI"

  info = {
    status: data.manifest?.lastUpdateRequest?.status ? null
    errors: data.manifest?.lastUpdateRequest?.errors
    manifest: data.manifest
    raw: data
  }

  if info.errors
    info.errors = JSON.stringify(info.errors, null, 2)
    logger.verbose info.errors
  logger.verbose "skill is in #{info.status} state"

  return info


updateSkill = (context, manifestContext) ->
  callSMAPI context, 'get-skill', {
    'skill-id': manifestContext.skillId
  }
  .catch (error) ->
    if error.code == 404
      Promise.reject "The skill ID stored in artifacts.json doesn't seem to exist in the deployment
        account. Have you deleted it manually in the dev console? If so, please delete it from the
        artifacts.json and try again."
    else
      Promise.reject error
  .then (data) ->
    needsUpdating = false
    info = parseSkillInfo data
    if info.status == 'FAILED'
      needsUpdating = true
    else
      try
        testObjectsEqual info.manifest, manifestContext.manifest
        logger.log "skill manifest up to date"
      catch err
        logger.verbose err
        logger.log "skill manifest mismatch"
        needsUpdating = true

    unless context.artifacts.get('skill-manifest-assets-md5') == manifestContext.assetsMd5
      logger.log "skill icons changed since last update"
      needsUpdating = true

    unless needsUpdating
      logger.log "skill manifest up to date"
      return Promise.resolve()

    logger.log "updating skill manifest"
    callSMAPI context, 'update-skill', {
      'skill-id': manifestContext.skillId
      'file': manifestContext.manifestFilename
    }
    .then (data) ->
      waitForSuccess context, manifestContext.skillId, 'update-skill'
    .then ->
      context.artifacts.save 'skill-manifest-assets-md5', manifestContext.assetsMd5


waitForSuccess = (context, skillId, operation) ->
  return new Promise (resolve, reject) ->
    checkStatus = ->
      logger.log "waiting for skill status after #{operation}"
      callSMAPI context, 'get-skill-status', {
        'skill-id': skillId
      }
      .then (data) ->
        info = parseSkillInfo data
        switch info.status
          when 'FAILED'
            logger.error info.errors
            return reject "skill in FAILED state"
          when 'SUCCEEDED'
            logger.log "#{operation} succeeded"
            context.artifacts.save 'skillId', skillId
            return resolve()
          when 'IN_PROGRESS'
            setTimeout checkStatus, 1000
          else
            logger.verbose data
            return reject "unknown skill state: #{info.status} while waiting on SMAPI"
        Promise.resolve()
      .catch (err) ->
        Promise.reject err
    checkStatus()


createSkill = (context, manifestContext) ->
  callSMAPI context, 'create-skill', {
    'file': manifestContext.manifestFilename
  }
  .then (data) ->
    # dig out the skill id
    # logger.log data
    lines = data.split '\n'
    skillId = null
    for line in lines
      [k, v] = line.split ':'
      if k.toLowerCase().indexOf('skill id') == 0
        skillId = v.trim()
        break
    unless skillId?
      throw "failed to extract skill ID from ask cli response to create-skill"
    logger.log "in progress skill id #{skillId}"
    manifestContext.skillId = skillId
    waitForSuccess context, skillId, 'create-skill'


writeDefaultManifest = (context, filename) ->
  logger.log "writing default skill.json"
  # try to make a nice looking name from the
  # what was the directory name
  name = context.projectInfo.name
  name = name.replace /[_\.\-]/gi, ' '
  name = name.replace /\s+/gi, ' '
  name = (name.split(' '))
  name = ( w[0].toUpperCase() + w[1...] for w in name )
  name = name.join ' '

  manifest = """
    ###
      This file exports an object that is a subset of the data
      specified for an Alexa skill manifest as defined at
      https://developer.amazon.com/docs/smapi/skill-manifest.html

      Please fill in fields as appropriate for this skill,
      including the name, descriptions, more regions, etc.

      At deployment time, this data will be augmented with
      generated information based on your skill code.
    ###

    module.exports =
      manifest:
        publishingInformation:
          isAvailableWorldwide: false,
          distributionCountries: [ 'US' ]
          distributionMode: 'PUBLIC'
          category: 'GAMES'
          testingInstructions: "replace with testing instructions"

          locales:
            "en-US":
              name: "#{name}"
              invocation: "#{name.toLowerCase()}"
              summary: "replace with brief description, no longer than 120 characters"
              description: "\""Longer description, goes to the skill store.
                Line breaks are supported."\""
              examplePhrases: [
                "Alexa, launch #{name}"
                "Alexa, open #{name}"
                "Alexa, play #{name}"
              ]
              keywords: [
                'game'
                'fun'
                'single player'
                'modify this list as appropriate'
              ]

        privacyAndCompliance:
          allowsPurchases: false
          usesPersonalInfo: false
          isChildDirected: false
          isExportCompliant: true
          containsAds: false

          locales:
            "en-US":
              privacyPolicyUrl: "http://yoursite/privacy.html",
              termsOfUseUrl: "http://yoursite/terms.html"
  """

  fs.writeFileSync filename, manifest, 'utf8'


waitForModelSuccess = (context, skillId, locale, operation) ->
  return new Promise (resolve, reject) ->
    checkStatus = ->
      logger.log "waiting for model #{locale} status after #{operation}"
      callSMAPI context, 'get-skill-status', {
        'skill-id': skillId
      }
      .then (data) ->
        try
          info = JSON.parse data
          info = info.interactionModel[locale]
        catch err
          logger.verbose data
          logger.error err
          return reject "failed to parse SMAPI result"

        switch info.lastUpdateRequest?.status
          when 'FAILED'
            logger.error info.errors
            return reject "skill in FAILED state"
          when 'SUCCEEDED'
            logger.log "model #{operation} succeeded"
            context.artifacts.save "skill-model-etag-#{locale}", info.eTag
            return resolve()
          when 'IN_PROGRESS'
            setTimeout checkStatus, 1000
          else
            logger.verbose data
            return reject "unknown skill state: #{info.status} while waiting on SMAPI"
        Promise.resolve()
    checkStatus()


updateModel = (context, manifestContext) ->
  promises = []
  for locale in manifestContext.locales
    promises.push updateModelForLocale context, manifestContext, locale
  Promise.all promises


updateModelForLocale = (context, manifestContext, localeInfo) ->
  locale = localeInfo.code

  modelDeployStart = new Date
  callSMAPI context, 'get-model', {
    'skill-id': manifestContext.skillId
    locale: locale
  }
  .catch (error) ->
    # it's fine if it doesn't exist yet, we'll upload
    unless error.code == 404
      throw "Error while reading #{locale} model, #{error.code} #{error.error}"
    Promise.resolve "{}"
  .then (data) ->
    model = context.skill.toModelV2 locale

    # patch in the invocation from the skill manifest
    model.languageModel.invocationName = localeInfo.invocation

    # note, SMAPI needs an extra
    # interactionModel key around the model
    model =
      interactionModel:model

    filename = path.join context.deployRoot, "model-#{locale}.json"
    fs.writeFileSync filename, JSON.stringify(model, null, 2), 'utf8'

    needsUpdate = false
    try
      data = JSON.parse data
      # the version number is a lamport clock, will always mismatch
      delete data.version
      testObjectsEqual model, data
      logger.log "#{locale} model up to date"
    catch err
      logger.verbose err
      logger.log "#{locale} model mismatch"
      needsUpdate = true

    unless needsUpdate
      logger.log "#{locale} model is up to date"
      return Promise.resolve()

    logger.log "#{locale} model update beginning"
    callSMAPI context, 'update-model', {
      'skill-id': manifestContext.skillId
      locale: locale
      file: filename
    }
    .then ->
      waitForModelSuccess context, manifestContext.skillId, locale, 'update-model'
    .then ->
      dt = (new Date) - modelDeployStart
      logger.log "#{locale} model update complete, total time #{dt}ms"


enableSkill = (context, manifestContext) ->
  logger.log "ensuring skill is enabled for testing"
  callSMAPI context, 'enable-skill', {
    'skill-id': manifestContext.skillId
  }

loadIspData = (context, manifestContext) ->
  logger.log "fetching isps from SMAPI"
  callSMAPI context, 'list-isp-for-skill', {
    'skill-id': manifestContext.skillId
    'stage': 'development'
  }
  .then (data) ->
    context.isps = {}
    for isp in JSON.parse(data)
      context.isps[isp.referenceName] = isp
  .catch (err) ->
    console.log "HERE"
    unless err.code == 'ENOENT'
      # ENOENT just means there is no ISP data on the server, that's fine
      throw err
    context.isps = {}

createOrUpdateIspData = (context, manifestContext) ->

  ispsPath = path.join context.projectRoot, 'isps'

  unless fs.existsSync ispsPath
    logger.log "no isp directory found at #{ispsPath}, skipping monetization upload"
    return Promise.resolve()

  logger.log "reconciling isp data from #{ispsPath}..."

  localIsps = []
  if fs.existsSync(ispsPath)
    for f in fs.readdirSync(ispsPath) when fs.lstatSync(path.join(ispsPath, f)).isFile()
      localIsp = {}
      localIsp.filePath = path.join(ispsPath, f)
      localIsp.data = JSON.parse fs.readFileSync(localIsp.filePath, 'utf8')
      localIsps.push localIsp

  promises = []
  monetizationLog = {}

  for localIsp in localIsps
    remoteIsp = context.isps[localIsp.data.referenceName]

    unless remoteIsp?

      # create product if does not exist
      promises.push new Promise (resolve, reject) ->
        referenceName = localIsp.data.referenceName
        logger.log "Creating isp #{referenceName} from #{localIsp.filePath}"
        callSMAPI context, 'create-isp', {
         'file': localIsp.filePath
        }
        .then (data) ->
          productId = data.substring(data.search("amzn1"), data.search(" based"))
          monetizationLog[referenceName] = {
            'action': 'created'
            'productId': productId
          }
          logger.log "Created isp from #{localIsp.filePath}"
          Promise.resolve productId
        .then (productId) ->
          logger.log "Linking isp #{referenceName} to the skill #{manifestContext.skillId}"
          callSMAPI context, 'associate-isp', {
            'isp-id': productId
            'skill-id': manifestContext.skillId
          }
          .then (data) ->
            resolve()

    else

      # update existing product
      promises.push new Promise (resolve, reject) ->
        referenceName = localIsp.data.referenceName
        productId = remoteIsp.productId
        remoteIsp.action = "updating"

        logger.log "Updating isp #{referenceName} from #{localIsp.filePath}"
        callSMAPI context, 'update-isp', {
          'isp-id': productId
          'file': localIsp.filePath
          'stage': 'development'
        }
        .then (data) ->
          logger.log data
          monetizationLog[referenceName] = {
            'action': 'modified'
            'productId': productId
          }
          resolve()


  for k, v of context.isps
    unless v.action?

      # delete product if local file does not exist
      promises.push new Promise (resolve, reject) ->
        v.action = "deleting"
        referenceName = v.referenceName
        productId = v.productId
        logger.log "Unlinking and Deleting isp #{referenceName}"
        callSMAPI context, 'disassociate-isp', {
          'isp-id': productId
          'skill-id': manifestContext.skillId
        }
        .then (data) ->
          logger.log data
        .then (data) ->
          callSMAPI context, 'delete-isp', {
            'isp-id': productId
            'stage': 'development'
          }
          .then (data) ->
            logger.log data
            monetizationLog[referenceName] = {
              'action': 'deleted'
              'productId': productId
            }
            resolve()

  Promise.all promises
  .then () ->
    context.artifacts.save "monetization", monetizationLog
    Promise.resolve()