{-# LANGUAGE OverloadedStrings, NamedFieldPuns, Rank2Types, TemplateHaskell,
    LiberalTypeSynonyms, RebindableSyntax, DataKinds, CPP #-}
module Main where
-- TODO:
-- * persistence
-- * routing

import Prelude hiding ((>>), return)

import Control.Applicative
import Data.String
import qualified Data.Text as T
import Data.Void
import qualified Data.Foldable as Foldable

import Lens.Family2
import Lens.Family2.Stock
import Lens.Family2.TH
import React
import React.DOM
import React.GHCJS
import React.Rebindable

#ifdef __GHCJS__
foreign import javascript unsafe "$1.trim()" trim :: JSString -> JSString
#else
trim :: JSString -> JSString
trim = undefined
#endif

-- MODEL

data Status = Active | Completed
    deriving Eq

data Todo = Todo
    { _text :: JSString
    , _status :: Status
    }

data PageState = PageState
    { _todos :: [Todo]
    , _typingValue :: T.Text
    }

$(makeLenses ''Todo)
$(makeLenses ''PageState)

initialPageState :: PageState
initialPageState = PageState
    [Todo "abc" Active, Todo "xyz" Completed,
     Todo "sjdfk" Active, Todo "ksljl" Completed]
    ""

data Key = Enter | Escape

data Transition
    = Typing JSString
    | HeaderKey Key
    | Check Int
    | DoubleClick
    | Destroy Int
    | ToggleAll
    | ClearCompleted

pageTransition :: Transition -> PageState -> PageState
pageTransition (Typing str) = handleTyping (fromJSString str)
pageTransition (HeaderKey Enter) = handleEnter
pageTransition (HeaderKey Escape) = handleEsc
pageTransition (Check i) = handleItemCheck i
pageTransition DoubleClick = handleLabelDoubleClick
pageTransition (Destroy i) = handleDestroy i
pageTransition ToggleAll = handleToggleAll
pageTransition ClearCompleted = clearCompleted

pageTransition' :: (PageState, Transition) -> (PageState, Maybe Void)
pageTransition' (state, signal) = (pageTransition signal state, Nothing)

-- UTILITY

toggleStatus :: Status -> Status
toggleStatus Active = Completed
toggleStatus Completed = Active

-- this traversal is in lens but lens-family has a weird ix which isn't
-- what we want. definition just copied from lens.
-- TODO(joel) just use lens?
ix' :: Int -> Traversal' [a] a
ix' k f xs0 | k < 0     = pure xs0
            | otherwise = go xs0 k where
    go [] _ = pure []
    go (a:as) 0 = (:as) <$> f a
    go (a:as) i = (a:) <$> (go as $! i - 1)

-- remove an item from the list by index
iFilter :: Int -> [a] -> [a]
iFilter 0 (a:as) = as
iFilter n (a:as) = a : iFilter (n-1) as

-- CONTROLLER

handleEnter :: PageState -> PageState
handleEnter oldState@PageState{_todos, _typingValue} =
    let trimmed = trim (toJSString _typingValue)
    in if trimmed == ""
           then oldState
           else PageState (_todos ++ [Todo trimmed Active]) ""

-- TODO exit editing
-- "If escape is pressed during the edit, the edit state should be left and
-- any changes be discarded."
handleEsc :: PageState -> PageState
handleEsc state = state & typingValue .~ ""

emitKeydown :: KeyboardEvent -> Maybe Transition
emitKeydown KeyboardEvent{key="Enter"} = Just (HeaderKey Enter)
emitKeydown KeyboardEvent{key="Escape"} = Just (HeaderKey Escape)
emitKeydown _ = Nothing

handleTyping :: T.Text -> PageState -> PageState
handleTyping _typingValue state = state{_typingValue}

statusOfToggle :: [Todo] -> Status
statusOfToggle _todos =
    let allActive = all (\Todo{_status} -> _status == Active) _todos
    in if allActive then Active else Completed

handleToggleAll :: PageState -> PageState
handleToggleAll state@PageState{_todos} = state{_todos=newTodos} where
    _status = toggleStatus $ statusOfToggle _todos
    newTodos = map (\todo -> todo{_status}) _todos

handleItemCheck :: Int -> PageState -> PageState
handleItemCheck todoNum state =
    state & todos . ix' todoNum . status %~ toggleStatus

-- TODO
handleLabelDoubleClick :: PageState -> PageState
handleLabelDoubleClick = id

handleDestroy :: Int -> PageState -> PageState
handleDestroy todoNum state = state & todos %~ iFilter todoNum

clearCompleted :: PageState -> PageState
clearCompleted state = state & todos %~ todosWithStatus Active

-- VIEW

-- "New todos are entered in the input at the top of the app. The input
-- element should be focused when the page is loaded preferably using the
-- autofocus input attribute. Pressing Enter creates the todo, appends it
-- to the todo list and clears the input. Make sure to .trim() the input
-- and then check that it's not empty before creating a new todo."
header :: PageState -> ReactNode Transition
header PageState{_typingValue} = header_ [ class_ "header" ] $ do
    h1_ [] $ text_ "todos"
    input_ [ class_ "new-todo"
           , placeholder_ "What needs to be done?"
           , autofocus_ True
           , value_ _typingValue
           , onChange (Just . Typing . value . target)
           , onKeyDown emitKeydown
           ]

todoView :: PageState -> Int -> ReactNode Transition
todoView PageState{_todos} i =
    let Todo{_text, _status} = _todos !! i
    in li_ [ class_ (if _status == Completed then "completed" else "") ] $ do
           div_ [ class_ "view" ] $ do
               input_ [ class_ "toggle"
                      , type_ "checkbox"
                      , checked_ (_status == Completed)
                      , onClick (const (Just (Check i)))
                      ]
               label_ [ onDoubleClick (const (Just DoubleClick)) ] $ text_ _text
               button_ [ class_ "destroy"
                       , onClick (const (Just (Destroy i)))
                       ] $ text_ ""

           -- TODO - onChange
           input_ [ class_ "edit", value_ (fromJSString _text) ]

todosWithStatus :: Status -> [Todo] -> [Todo]
todosWithStatus stat = filter (\Todo{_status} -> _status == stat)

mainBody_ :: PageState -> ReactNode Transition
mainBody_ = classLeaf $ dumbClass
    { name = "MainBody"
    , renderFn = \st@PageState{_todos} _ ->
          section_ [ class_ "main" ] $ do
              -- TODO - onChange
              input_ [ class_ "toggle-all", type_ "checkbox" ]
              label_ [ for_ "toggle-all" , onClick (const (Just ToggleAll)) ]
                  $ text_ "Mark all as complete"

              let blah = text_ "" >> text_ ""
              ul_ [ class_ "todo-list" ] $ case length _todos of
                  0 -> blah
                  _ -> Foldable.foldMap (todoView st) [0 .. length _todos - 1]
    }

innerFooter_ :: PageState -> ReactNode Transition
innerFooter_ = classLeaf $ dumbClass
    { name = "InnerFooter"
    , renderFn = \PageState{_todos} _ -> footer_ [ class_ "footer" ] $ do
          let activeCount = length (todosWithStatus Active _todos)
          let inactiveCount = length (todosWithStatus Completed _todos)

          -- "Displays the number of active todos in a pluralized form. Make sure
          -- the number is wrapped by a <strong> tag. Also make sure to pluralize
          -- the item word correctly: 0 items, 1 item, 2 items. Example: 2 items
          -- left"
          span_ [ class_ "todo-count" ] $ do
              strong_ [] (text_ (toJSString (show activeCount)))

              text_ $ if activeCount == 1 then " item left" else " items left"

          ul_ [ class_ "filters" ] $ do
            li_ [] $ a_ [ class_ "selected" ] "All"
            li_ [] $ a_ [] "Active"
            li_ [] $ a_ [] "Completed"

          unless (inactiveCount == 0) $
              button_ [ class_ "clear-completed" , onClick (const (Just ClearCompleted)) ] $
                  text_ (toJSString ("Clear completed (" ++ show inactiveCount ++ ")"))
    }

outerFooter_ :: () -> ReactNode Transition
outerFooter_ = classLeaf $ dumbClass
    { name = "OuterFooter"
    , renderFn = \_ _ -> footer_ [ class_ "info" ] $ do
          -- TODO react complains about these things not having keys even though
          -- they're statically defined. figure out how to fix this.
          p_ [] $ text_ "Double-click to edit a todo"
          p_ [] $ do
              text_ "Created by "
              a_ [ href_ "http://joelburget.com" ] $ text_ "Joel Burget"
          p_ [] $ do
              text_ "Part of "
              a_ [ href_ "http://todomvc.com" ] $ text_ "TodoMVC"
    }

wholePage_ :: () -> ReactNode Void
wholePage_ = classLeaf $ smartClass
    { name = "WholePage"
    , transition = pageTransition'
    , initialState = initialPageState
    , renderFn = \_ s@PageState{_todos} -> div_ [] $ do
          section_ [ class_ "todoapp" ] $ do
              header s

              -- "When there are no todos, #main and #footer should be hidden."
              unless (null _todos) $ do
                  mainBody_ s
                  innerFooter_ s
          outerFooter_ ()
    }

main = do
    Just doc <- currentDocument
    let elemId :: JSString
        elemId = "inject"
    Just elem <- documentGetElementById doc elemId
    render (wholePage_ ()) elem
