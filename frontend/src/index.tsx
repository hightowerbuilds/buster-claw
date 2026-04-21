import { render } from "solid-js/web";
import { QueryClient, QueryClientProvider } from "@tanstack/solid-query";
import App from "./App";
import "./styles.css";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
    },
  },
});

render(
  () => (
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  ),
  document.getElementById("root")!,
);
