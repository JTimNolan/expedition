#!/bin/bash
# Builds prod versions of the android (expedition.apk), iOS and web apps
# and deploys to app.expeditiongame.com, including invalidating the files on cloudfront (CDN)

# Requires the aws cli for s3 deploys (make sure to set your bucket region!)
# Requires that android-release-key.keystore be in the directory above
# Requires that you run `aws configure set preview.cloudfront true` to enable cloudfront invalidation

# To generate a new key:
# keytool -genkey -v -keystore android-release-key.keystore -alias expedition_android -keyalg RSA -keysize 2048 -validity 10000
# Tutorial:
# http://developer.android.com/tools/publishing/app-signing.html#signing-manually

function init() {
  # Read current version (as a string) from package.json
  key="version"
  re="\"($key)\": \"([^\"]*)\""
  package=`cat package.json`
  if [[ $package =~ $re ]]; then
    version="${BASH_REMATCH[2]}"
  fi
}

function prebuild() {
  # clear out old build files to prevent conflicts
  rm -rf www
  rm platforms/android/app/build/outputs/apk/debug/app-debug.apk
  rm platforms/android/app/build/outputs/apk/release/expedition.apk
}

function deploybeta() {
  export NODE_ENV='dev'
  export API_HOST='http://betaapi.expeditiongame.com'
  npm run build-all
  aws s3 cp www s3://beta.expeditiongame.com --recursive --region us-east-2
}

function deployprod() {
  printf "\nEnter android keystore passphrase: "
  read -s androidkeystorepassphrase

  # Rebuild the web app files
  export NODE_ENV='production'
  export API_HOST='https://api.expeditiongame.com'
  export OAUTH2_CLIENT_ID='545484140970-r95j0rmo8q1mefo0pko6l3v6p4s771ul.apps.googleusercontent.com'
  webpack --config ./webpack.dist.config.js

  # Android: build the signed prod app
  cordova build --release android
  # Signing the release APK
  jarsigner -storepass $androidkeystorepassphrase -verbose -sigalg SHA1withRSA -digestalg SHA1 -keystore ../../../android-release-key.keystore platforms/android/app/build/outputs/apk/release/app-release-unsigned.apk expedition_android
  # Verification:
  jarsigner -verify -verbose -certs platforms/android/app/build/outputs/apk/release/app-release-unsigned.apk
  # Aligning memory blocks (takes less RAM on app)
  ./zipalign -v 4 platforms/android/app/build/outputs/apk/release/app-release-unsigned.apk platforms/android/app/build/outputs/apk/release/expedition.apk

  # iOS
  cordova build ios

  # Deploy web app to prod with 1 day cache for most files, 6 month cache for art assets
  export AWS_DEFAULT_REGION='us-east-2'
  aws s3 cp www s3://app.expeditiongame.com --recursive --exclude '*.mp3' --exclude '*.jpg' --exclude '*.png' --cache-control max-age=86400 --cache-control public
  aws s3 cp www s3://app.expeditiongame.com --recursive --exclude '*' --include '*.mp3' --include '*.jpg' --include '*.png' --cache-control max-age=15552000 --cache-control public

  # Upload the APK for side-loading, and archive it by version number
  aws s3 cp platforms/android/app/build/outputs/apk/release/expedition.apk s3://app.expeditiongame.com/expedition.apk --cache-control public
  aws s3 cp s3://app.expeditiongame.com/expedition.apk s3://app.expeditiongame.com/apk-archive/expedition-$version.apk --cache-control public

  # Upload package.json for API's version check
  aws s3 cp package.json s3://app.expeditiongame.com/package.json

  # Invalidate files on cloudfront
  aws cloudfront create-invalidation --distribution-id EDFP2F13AASZW --paths /\*
}

#### THE ACTUAL SCRIPT ####

init
echo "Where would you like to deploy the app? Current version: ${version}"
OPTIONS="Beta Prod"
select opt in $OPTIONS; do
  if [ "$opt" = "Beta" ]; then
    read -p "This will remove built files, rebuild the app, and deploy to S3. Continue? (Y/n)" -n 1 -r
    echo
    if [[ ${REPLY:-Y} =~ ^[Yy]$ ]]; then
      prebuild
      deploybeta
    else
      echo "Beta deploy cancelled"
    fi
  elif [ "$opt" = "Prod" ]; then
    read -p "Did you test a quest on the beta build? (y/N) " -n 1
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      prebuild
      deployprod
    else
      echo "Prod build cancelled until tested on beta."
    fi
  else
    echo "Invalid option - exiting"
  fi
done
