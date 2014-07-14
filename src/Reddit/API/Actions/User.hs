module Reddit.API.Actions.User where

import qualified Reddit.API.Routes.User as Route
import Reddit.API.Types
import Reddit.API.Types.Reddit

import APIBuilder

getUserInfo :: Username -> Reddit User
getUserInfo = RedditT . runRoute . Route.aboutUser

isUsernameAvailable :: Username -> Reddit Bool
isUsernameAvailable = RedditT . runRoute . Route.usernameAvailable

aboutMe :: Reddit User
aboutMe = RedditT $ runRoute Route.aboutMe
