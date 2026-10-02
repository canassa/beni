// solidjs/solid-todomvc's src/index.tsx (full.tsx) cut to the features
// tests/corpus/browser/tea/TodoMVC.beni has: no editing (no double-click,
// no edit field, no `editingTodoId`), and the filter read from the address
// at start as well as on `hashchange`. Everything else is the official
// app's code, unchanged.
import { createMemo, createEffect, onCleanup, Show, For } from "solid-js";
import { createStore } from "solid-js/store";
import { render } from "solid-js/web";

type Todo = {
  id: number;
  title: string;
  completed: boolean;
};

type Filter = "all" | "active" | "completed"

type TodoStore = {
  counter: number;
  todos: Todo[];
  showMode: Filter;
};

const ENTER_KEY = 13;

const LOCAL_STORAGE_KEY = "todos-solid";
function createLocalStore<T extends object>(value: T) {
  // load stored todos on init
  const stored = localStorage.getItem(LOCAL_STORAGE_KEY),
    [state, setState] = createStore<T>(stored ? JSON.parse(stored) : value);

  // JSON.stringify creates deps on every iterable field
  createEffect(() => localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(state)));
  return [state, setState] as const;
}

const TodoApp = () => {
  const [state, setState] = createLocalStore<TodoStore>({
      counter: 1,
      todos: [],
      showMode: "all"
    }),
    remainingCount = createMemo(
      () => state.todos.length - state.todos.filter((todo) => todo.completed).length
    ),
    filterList = (todos: Todo[]) => {
      if (state.showMode === "active") return todos.filter((todo) => !todo.completed);
      else if (state.showMode === "completed") return todos.filter((todo) => todo.completed);
      else return todos;
    },
    removeTodo = (todoId: number) => setState("todos", (t) => t.filter((item) => item.id !== todoId)),
    editTodo = (todo: Partial<Todo>) => setState("todos", (item) => item.id === todo.id, todo),
    clearCompleted = () => setState("todos", (t) => t.filter((todo) => !todo.completed)),
    toggleAll = (completed: boolean) =>
      setState("todos", (todo) => todo.completed !== completed, { completed }),
    addTodo = ({ target, keyCode }: KeyboardEvent) => {
      const title = (target as HTMLInputElement).value.trim();
      if (keyCode === ENTER_KEY && title) {
        setState({
          todos: [{ title, id: state.counter, completed: false }, ...state.todos],
          counter: state.counter + 1
        });
        (target as HTMLInputElement).value = "";
      }
    },
    toggle = (todoId: number, { target: { checked } }: { target: HTMLInputElement }) => editTodo({ id: todoId, completed: checked });

  const locationHandler = () => setState("showMode", location.hash.slice(2) as Filter || "all");
  locationHandler();
  window.addEventListener("hashchange", locationHandler);
  onCleanup(() => window.removeEventListener("hashchange", locationHandler));

  return (
    <section class="todoapp">
      <header class="header">
        <h1>todos</h1>
        <input class="new-todo" placeholder="What needs to be done?" onKeyDown={addTodo} />
      </header>

      <Show when={state.todos.length > 0}>
        <section class="main">
          <input
            id="toggle-all"
            class="toggle-all"
            type="checkbox"
            checked={!remainingCount()}
            onInput={({ target: { checked } }) => toggleAll(checked)}
          />
          <label for="toggle-all" />
          <ul class="todo-list">
            <For each={filterList(state.todos)}>
              {(todo) => (
                <li class="todo" classList={{ completed: todo.completed }}>
                  <div class="view">
                    <input class="toggle" type="checkbox" checked={todo.completed} onInput={[toggle, todo.id]}/>
                    <label>{todo.title}</label>
                    <button class="destroy" onClick={[removeTodo, todo.id]} />
                  </div>
                </li>
              )}
            </For>
          </ul>
        </section>

        <footer class="footer">
          <span class="todo-count">
            <strong>{remainingCount()}</strong>{" "}
            {remainingCount() === 1 ? " item " : " items "} left
          </span>
          <ul class="filters">
            <li><a href="#/" classList={{selected: state.showMode === "all"}}>All</a></li>
            <li><a href="#/active" classList={{selected: state.showMode === "active"}}>Active</a></li>
            <li><a href="#/completed" classList={{selected: state.showMode === "completed"}}>Completed</a></li>
          </ul>
          <Show when={remainingCount() !== state.todos.length}>
            <button class="clear-completed" onClick={clearCompleted}>
              Clear completed
            </button>
          </Show>
        </footer>
      </Show>
    </section>
  );
};

render(TodoApp, document.getElementById("main")!);
